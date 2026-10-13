#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SafeCleanupScopeCardLayoutTests: XCTestCase {
    func testProductionCardsReflowAtTheirOwnWidthWithoutOverlapsOrClippedTitles() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = ScopeCardLanguageScope(language)
            defer { languageScope.restore() }
            for dark in [false, true] {
                let model = ScopeCardSelectionFixture()
                let host = ScopeCardLayoutHost(model: model, width: 560, dark: dark)
                defer { host.close() }
                // 304 pt is a narrow action column in a wide window. 280 pt
                // must reflow even though the outer window may still be wide.
                let widths: [(CGFloat, Int)] = [(560, 2), (400, 2), (304, 2),
                                                (280, 1), (180, 1), (400, 2)]
                for (width, columns) in widths {
                    host.resize(width: width)
                    let frames = try await host.frames(expectedWidth: width)
                    let group = try XCTUnwrap(frames["safeCleanup.scope.cards"])
                    let cards = try SafeCleanupScanScope.allCases.map {
                        try XCTUnwrap(frames["safeCleanup.scope.card.\($0.rawValue)"])
                    }
                    XCTAssertEqual(group.width, width, accuracy: 0.5)
                    for (index, scope) in SafeCleanupScanScope.allCases.enumerated() {
                        let card = cards[index]
                        let title = try XCTUnwrap(frames["safeCleanup.scope.title.\(scope.rawValue)"])
                        let icon = try XCTUnwrap(frames["safeCleanup.scope.icon.\(scope.rawValue)"])
                        XCTAssertTrue(group.insetBy(dx: -0.5, dy: -0.5).contains(card))
                        XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(title))
                        XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(icon))
                        XCTAssertGreaterThanOrEqual(card.height, 88)
                        XCTAssertGreaterThanOrEqual(title.height, 12)
                        XCTAssertGreaterThanOrEqual(title.minY - icon.maxY, 5.5)
                        XCTAssertGreaterThanOrEqual(title.minX - card.minX, 11.5)
                        XCTAssertGreaterThanOrEqual(card.maxX - title.maxX, 11.5)
                        XCTAssertEqual(icon.size.width, 40, accuracy: 0.5)
                        XCTAssertEqual(icon.size.height, 40, accuracy: 0.5)
                        if columns == 1 || index.isMultiple(of: columns) {
                            XCTAssertEqual(card.minX, group.minX, accuracy: 0.5)
                        } else {
                            XCTAssertEqual(card.minY, cards[index - 1].minY, accuracy: 0.5)
                            XCTAssertEqual(card.minX - cards[index - 1].maxX, 8, accuracy: 0.5)
                            XCTAssertEqual(card.width, cards[index - 1].width, accuracy: 0.5)
                        }
                        if index >= columns {
                            XCTAssertEqual(card.minY - cards[index - columns].maxY, 8, accuracy: 0.5)
                        }
                    }
                    for index in cards.indices {
                        for other in cards.indices where other > index {
                            XCTAssertTrue(cards[index].intersection(cards[other]).isNull,
                                "Actual native cards must not overlap at \(width) pt")
                        }
                    }
                }
            }
        }
    }

    func testNativeButtonsKeepExactSelectionAcrossColumnChangesIncludingNoScopes() async throws {
        let language = ScopeCardLanguageScope(.english)
        defer { language.restore() }
        let model = ScopeCardSelectionFixture()
        let host = ScopeCardLayoutHost(model: model, width: 400, dark: false)
        defer { host.close() }
        _ = try await host.frames(expectedWidth: 400)
        for (index, scope) in SafeCleanupScanScope.allCases.enumerated() {
            let label = englishLabel(scope)
            try await host.waitForAccessibility(label: label, expectedValue: "Selected")
            XCTAssertTrue(try host.press(label: label))
            let expected = Set(SafeCleanupScanScope.allCases.dropFirst(index + 1))
            try await host.waitForSelection(expected)
            XCTAssertEqual(model.selectedScopes, expected)
            XCTAssertEqual(model.toggleCount[scope], 1)
            host.resize(width: index.isMultiple(of: 2) ? 260 : 560)
            _ = try await host.frames(expectedWidth: index.isMultiple(of: 2) ? 260 : 560)
            try await host.waitForAccessibility(label: label, expectedValue: "Not selected")
            XCTAssertEqual(try host.accessibilityValue(label: label), "Not selected")
        }
        XCTAssertTrue(model.selectedScopes.isEmpty, "Presentation must allow the existing all-deselected state")
        try await host.waitForAccessibility(label: englishLabel(.logs), expectedValue: "Not selected")
        XCTAssertTrue(try host.press(label: englishLabel(.logs)))
        try await host.waitForSelection([.logs])
        host.resize(width: 304)
        _ = try await host.frames(expectedWidth: 304)
        try await host.waitForAccessibility(label: englishLabel(.logs), expectedValue: "Selected")
        XCTAssertEqual(model.selectedScopes, [.logs])
        XCTAssertEqual(try host.accessibilityValue(label: englishLabel(.logs)), "Selected")
        XCTAssertEqual(model.toggleCount[.logs], 2)
    }

    func testDaylightProductionIconsKeepFourDistinctPigments() async throws {
        let language = ScopeCardLanguageScope(.english)
        defer { language.restore() }
        let host = ScopeCardLayoutHost(model: ScopeCardSelectionFixture(), width: 400, dark: false)
        defer { host.close() }
        let frames = try await host.frames(expectedWidth: 400)
        var colors = [[CGFloat]]()
        for scope in SafeCleanupScanScope.allCases {
            let rect = try XCTUnwrap(frames["safeCleanup.scope.icon.\(scope.rawValue)"])
            let bitmap = try host.capture(rect)
            var pixels = [[CGFloat]]()
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                    guard let maximum = rgb.max(), let minimum = rgb.min(), maximum > 0,
                          (maximum - minimum) / maximum > 0.4,
                          maximum - minimum > 0.12 else { continue }
                    pixels.append(rgb)
                }
            }
            XCTAssertGreaterThan(pixels.count, 20, "\(scope) must render a colored symbol, not a gray icon")
            let average = (0..<3).map { channel in
                pixels.reduce(CGFloat.zero) { $0 + $1[channel] } / CGFloat(max(1, pixels.count))
            }
            colors.append(average)
        }
        for index in colors.indices {
            for other in colors.indices where other > index {
                let distance = zip(colors[index], colors[other]).map { abs($0.0 - $0.1) }.max() ?? 0
                XCTAssertGreaterThan(distance, 0.04,
                    "Rendered \(SafeCleanupScanScope.allCases[index]) and \(SafeCleanupScanScope.allCases[other]) icons need distinct category colors")
            }
        }
    }

    private func englishLabel(_ scope: SafeCleanupScanScope) -> String {
        switch scope {
        case .caches: "System Caches"
        case .logs: "Log Files"
        case .temporaryFiles: "Temporary Files"
        case .downloadResidue: "Download Residue"
        }
    }
}

@MainActor
private final class ScopeCardSelectionFixture: ObservableObject {
    @Published var selectedScopes = Set(SafeCleanupScanScope.allCases)
    private(set) var toggleCount: [SafeCleanupScanScope: Int] = [:]

    func toggle(_ scope: SafeCleanupScanScope) {
        toggleCount[scope, default: 0] += 1
        if selectedScopes.contains(scope) { selectedScopes.remove(scope) }
        else { selectedScopes.insert(scope) }
    }
}

private struct ScopeCardFixtureView: View {
    @ObservedObject var model: ScopeCardSelectionFixture
    var body: some View {
        SafeCleanupScopeCards(selectedScopes: model.selectedScopes, onToggle: model.toggle)
    }
}

@MainActor
private final class ScopeCardFrameRecorder {
    var frames: [String: CGRect] = [:]
    var globalFrames: [String: CGRect] = [:]
}

@MainActor
private final class ScopeCardFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class ScopeCardLayoutHost {
    private let window: NSWindow
    private let controller: NSHostingController<AnyView>
    private let recorder = ScopeCardFrameRecorder()
    private let model: ScopeCardSelectionFixture

    init(model: ScopeCardSelectionFixture, width: CGFloat, dark: Bool) {
        _ = NSApplication.shared
        self.model = model
        let root = ScopeCardFixtureView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutProbe("fixture.scope.viewport")
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.accessibilityEnabled, true)
            .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .cleanup))
            .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                Task { @MainActor [weak recorder] in
                    recorder?.globalFrames = frames
                    guard let origin = frames["fixture.scope.viewport"]?.origin else {
                        recorder?.frames = frames
                        return
                    }
                    recorder?.frames = frames.mapValues {
                        $0.offsetBy(dx: -origin.x, dy: -origin.y)
                    }
                }
            }
        controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        window = ScopeCardFixtureWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: width, height: 720))
        layoutNativeHierarchy()
    }

    func resize(width: CGFloat) {
        window.setContentSize(CGSize(width: width, height: 720))
        layoutNativeHierarchy()
    }

    func frames(expectedWidth: CGFloat) async throws -> [String: CGRect] {
        let required = Set(["fixture.scope.viewport", "safeCleanup.scope.cards"] + SafeCleanupScanScope.allCases.flatMap { scope in
            ["safeCleanup.scope.card.\(scope.rawValue)", "safeCleanup.scope.icon.\(scope.rawValue)",
             "safeCleanup.scope.title.\(scope.rawValue)"]
        })
        var previous: [String: CGRect]?
        var stablePasses = 0
        for _ in 0..<120 {
            layoutNativeHierarchy()
            await Task.yield()
            let current = recorder.frames
            if required.isSubset(of: Set(current.keys)),
               abs((current["safeCleanup.scope.cards"]?.width ?? 0) - expectedWidth) < 0.5 {
                stablePasses = previous == current ? stablePasses + 1 : 0
                previous = current
                if stablePasses >= 3 { return current }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw fixtureError("Native scope frames did not settle at \(expectedWidth) pt; missing=\(required.subtracting(recorder.frames.keys).sorted()); nativeBounds=\(controller.view.bounds); contentBounds=\(String(describing: window.contentView?.bounds)); frames=\(recorder.frames.sorted { $0.key < $1.key }); globalFrames=\(recorder.globalFrames.sorted { $0.key < $1.key })")
    }

    func press(label: String) throws -> Bool {
        let button = try XCTUnwrap(findElement(label: label))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard button.responds(to: selector) else {
            throw fixtureError("Native element cannot perform press: \(label)")
        }
        // AppKit's public action returns BOOL, not an Objective-C object.
        typealias NativePress = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(button.method(for: selector))
        return unsafeBitCast(implementation, to: NativePress.self)(button, selector)
    }

    func accessibilityValue(label: String) throws -> String? {
        let element = try XCTUnwrap(findElement(label: label))
        return nativeText(objectValue(element, selector: "accessibilityValue"))
    }

    func waitForAccessibility(label: String, expectedValue: String) async throws {
        for _ in 0..<100 {
            layoutNativeHierarchy()
            await Task.yield()
            if let element = findElement(label: label),
               nativeText(objectValue(element, selector: "accessibilityValue")) == expectedValue { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw fixtureError("Native AX button/value did not publish: \(label)=\(expectedValue); snapshot=\(nativeAccessibilitySnapshot())")
    }

    func waitForSelection(_ expected: Set<SafeCleanupScanScope>) async throws {
        for _ in 0..<100 {
            layoutNativeHierarchy()
            await Task.yield()
            if model.selectedScopes == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw fixtureError("Native button did not publish the selected scopes; expected=\(expected); actual=\(model.selectedScopes); snapshot=\(nativeAccessibilitySnapshot())")
    }

    func capture(_ rect: CGRect) throws -> NSBitmapImageRep {
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    private func findElement(label: String) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ element: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            let matches = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].contains {
                nativeText(objectValue(element, selector: $0)) == label
            }
            if matches, isNativeButton(element) { return element }
            let children = nativeChildren(element)
            for child in children {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(controller.view) ?? find(window)
    }

    private func objectValue(_ object: NSObject, selector: String) -> AnyObject? {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func nativeText(_ value: AnyObject?) -> String? {
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func nativeChildren(_ object: NSObject) -> [NSObject] {
        let children = objectValue(object, selector: "accessibilityChildren") as? [Any] ?? []
        return children.compactMap { $0 as? NSObject }
    }

    private func isNativeButton(_ object: NSObject) -> Bool {
        object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            && nativeText(objectValue(object, selector: "accessibilityRole")) == NSAccessibility.Role.button.rawValue
    }

    private func nativeAccessibilitySnapshot() -> [String] {
        var visited = Set<ObjectIdentifier>()
        var rows = [String]()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted, rows.count < 120 else { return }
            let children = objectValue(object, selector: "accessibilityChildren") as? [Any] ?? []
            let names = ["accessibilityRole", "accessibilityTitle", "accessibilityLabel", "accessibilityValue"].map {
                "\($0)=\(nativeText(objectValue(object, selector: $0)) ?? "nil")"
            }.joined(separator: ", ")
            rows.append("\(type(of: object)): \(names), children=\(children.count), bridged=\(children.compactMap { $0 as? NSObject }.count), press=\(isNativeButton(object))")
            for child in children.compactMap({ $0 as? NSObject }) { collect(child) }
        }
        collect(controller.view)
        collect(window)
        return rows
    }

    private func layoutNativeHierarchy() {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func fixtureError(_ description: String) -> NSError {
        let failure = NSError(domain: "SafeCleanupScopeCardLayoutTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
        FileHandle.standardError.write(Data("Native fixture failure: \(failure.domain):\(failure.code) \(failure.localizedDescription)\n".utf8))
        return failure
    }

    func close() {
        window.contentViewController = nil
        window.close()
    }
}

@MainActor
private final class ScopeCardLanguageScope {
    private let original: [String: Any]
    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }
    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
#endif
