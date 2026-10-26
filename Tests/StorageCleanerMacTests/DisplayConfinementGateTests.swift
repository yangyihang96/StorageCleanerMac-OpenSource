import AppKit
import ObjectiveC
import Photos
import ServiceManagement
import UserNotifications
import XCTest
@testable import StorageCleanerMac

/// D106: the gate's decisions, routed through the real intercepted entry
/// points with every original call replaced by a recorder, so no window,
/// app, URL or system UI reaches the screen. Windows are borderless,
/// deferred and never shown; displays are fixtures.
final class DisplayConfinementGateTests: XCTestCase {
    private static let main = DisplayConfinementPolicyTests.main
    private static let target = DisplayConfinementPolicyTests.target
    private static let fixtureURL = URL(string: "https://example.invalid/d106")!
    private static let fixtureApplication = URL(fileURLWithPath: "/nonexistent/D106Fixture.app")

    private var saved: (mode: DisplayConfinementGate.Mode,
                        sink: (@Sendable (DisplayConfinementGate.Event) -> Void)?,
                        onViolation: (@Sendable (DisplayConfinementGate.Event) -> Void)?)?

    override func setUp() {
        super.setUp()
        let gate = DisplayConfinementGate.shared
        saved = (gate.currentMode, gate.eventSink, gate.violationHandler)
    }

    override func tearDown() {
        if let saved {
            DisplayConfinementGate.shared.restore(mode: saved.mode, sink: saved.sink, onViolation: saved.onViolation)
        }
        super.tearDown()
    }

    func testTheTestBundleInstalledTheGateBeforeAnyTest() throws {
        let mode = try XCTUnwrap(saved?.mode)
        XCTAssertNotEqual(mode, .inactive, "the load-time bootstrap must activate the gate")
        if ProcessInfo.processInfo.environment[TestDisplayGate.displayKey] == nil {
            guard case .denyAll = mode else { return XCTFail("without a named display tests show no window: \(mode)") }
        }
        XCTAssertNotNil(saved?.onViolation, "a refusal must fail the running test")
    }

    func testEveryEntryPointIsReplacedOnItsOwnClass() throws {
        let installed = DisplayConfinementGate.interceptedImplementations
        let windowEntries: [(Selector, String)] = [
            (#selector(NSWindow.orderFront(_:)), "orderFront:"),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), "makeKeyAndOrderFront:"),
            (#selector(NSWindow.orderBack(_:)), "orderBack:"),
            (#selector(NSWindow.orderFrontRegardless), "orderFrontRegardless"),
            (#selector(NSWindow.order(_:relativeTo:)), "orderWindow:relativeTo:"),
            (#selector(NSWindow.setIsVisible(_:)), "setIsVisible:"),
            (#selector(NSWindow.setFrame(_:display:)), "setFrame:display:"),
            (#selector(NSWindow.setFrame(_:display:animate:)), "setFrame:display:animate:"),
            (#selector(NSWindow.setFrameOrigin(_:)), "setFrameOrigin:"),
            (#selector(NSWindow.setFrameTopLeftPoint(_:)), "setFrameTopLeftPoint:"),
            (#selector(NSWindow.beginSheet(_:completionHandler:)), "beginSheet:completionHandler:"),
            (#selector(NSWindow.beginCriticalSheet(_:completionHandler:)), "beginCriticalSheet:completionHandler:")
        ]
        for (selector, name) in windowEntries {
            let replacement = try XCTUnwrap(installed["NSWindow." + name], name)
            XCTAssertEqual(class_getMethodImplementation(NSWindow.self, selector), replacement, name)
            // NSPanel inherits the replacement or has its own implementation wrapped.
            let panel = class_getMethodImplementation(NSPanel.self, selector)
            XCTAssertTrue(panel == replacement || panel == installed["NSPanel." + name], "NSPanel " + name)
        }
        let instanceEntries: [(AnyClass, Selector, String)] = [
            (NSApplication.self, #selector(NSApplication.runModal(for:)), "NSApplication.runModalForWindow:"),
            (NSApplication.self, #selector(NSApplication.beginModalSession(for:)), "NSApplication.beginModalSessionForWindow:"),
            (NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), "NSWorkspace.openURL:"),
            (NSWorkspace.self, #selector(NSWorkspace.activateFileViewerSelecting(_:)),
             "NSWorkspace.activateFileViewerSelectingURLs:"),
            (NSWorkspace.self, #selector(NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)),
             "NSWorkspace.selectFile:inFileViewerRootedAtPath:"),
            (UNUserNotificationCenter.self, #selector(UNUserNotificationCenter.requestAuthorization(options:completionHandler:)),
             "UNUserNotificationCenter.requestAuthorizationWithOptions:completionHandler:"),
            (UNUserNotificationCenter.self, #selector(UNUserNotificationCenter.add(_:withCompletionHandler:)),
             "UNUserNotificationCenter.addNotificationRequest:withCompletionHandler:")
        ]
        for entry in instanceEntries {
            let (cls, selector, key): (AnyClass, Selector, String) = entry
            let replacement = try XCTUnwrap(installed[key], key)
            XCTAssertEqual(class_getMethodImplementation(cls, selector), replacement, key)
        }
        for key in [
            "NSWorkspace.openURL:configuration:completionHandler:",
            "NSWorkspace.openURLs:withApplicationAtURL:configuration:completionHandler:",
            "NSWorkspace.openApplicationAtURL:configuration:completionHandler:"
        ] {
            XCTAssertNotNil(installed[key], key)
        }
        let classEntries: [(AnyClass, Selector, String)] = [
            (SMAppService.self, #selector(SMAppService.openSystemSettingsLoginItems),
             "SMAppService.openSystemSettingsLoginItems"),
            (PHPhotoLibrary.self, #selector(PHPhotoLibrary.requestAuthorization(for:handler:)
                as (PHAccessLevel, @escaping @Sendable (PHAuthorizationStatus) -> Void) -> Void),
             "PHPhotoLibrary.requestAuthorizationForAccessLevel:handler:")
        ]
        for entry in classEntries {
            let (cls, selector, key): (AnyClass, Selector, String) = entry
            let replacement = try XCTUnwrap(installed[key], key)
            XCTAssertEqual(class_getMethodImplementation(object_getClass(cls), selector), replacement, key)
        }
    }

    /// 2026-10-20 (BOARD N27): the gate finds window classes image by image,
    /// filtered by superclass. `objc_copyClassList` realized every class in
    /// the process when the test bundle loaded; realizing ContactsUICore's
    /// Swift classes initialized `CNContactStore`, which opened the user's
    /// address book and tried to write its preferences in every test run,
    /// even a single test. Both walks found the same 175 window classes.
    func testWindowClassesAreFoundWithoutRealizingEveryClass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Support/DisplayConfinement.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("objc_copyClassList("))
        XCTAssertTrue(source.contains("objc_enumerateClasses(fromImage:"))
    }

    func testNoLoadedWindowClassBypassesTheGate() {
        XCTAssertEqual(DisplayConfinementGate.uncoveredWindowOverrides(), [])
        let ownImplementations = DisplayConfinementGate.interceptedImplementations.keys
            .filter { !$0.hasPrefix("NSWindow.") && !$0.hasPrefix("NSApplication.") && !$0.hasPrefix("NSWorkspace.")
                && !$0.hasPrefix("SMAppService.") && !$0.hasPrefix("UNUserNotificationCenter.")
                && !$0.hasPrefix("PHPhotoLibrary.") }
            .sorted()
        print("D106 window classes with their own wrapped implementation: \(ownImplementations)")
    }

    @MainActor
    func testDenyAllRefusesEveryOrderingEntryAndKeepsTheWindowHidden() {
        let recorder = configure(.denyAll(reason: "fixture"))
        let window = Self.hiddenWindow()
        window.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderBack(nil)
        window.orderFrontRegardless()
        window.order(.above, relativeTo: 0)
        window.setIsVisible(true)
        XCTAssertEqual(recorder.events.map(\.entry), [
            "orderFront:", "makeKeyAndOrderFront:", "orderBack:", "orderFrontRegardless",
            "orderWindow:relativeTo:", "setIsVisible:"
        ])
        XCTAssertTrue(recorder.events.allSatisfy { $0.kind == .refused && $0.detail == "fixture" })
        XCTAssertEqual(recorder.violations.count, 6)
        XCTAssertEqual(recorder.originals, [])
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testConfineMovesAHiddenWindowOntoTheTargetBeforeItIsOrdered() throws {
        let recorder = configure(.confine(displayName: Self.target.name), screens: [Self.main, Self.target])
        let onMain = CGRect(x: 100, y: 100, width: 400, height: 300)
        let window = Self.hiddenWindow(frame: onMain)
        window.makeKeyAndOrderFront(nil)

        XCTAssertEqual(recorder.originals, ["makeKeyAndOrderFront:"])
        let moved = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(moved.kind, .moved)
        XCTAssertEqual(moved.before, onMain)
        XCTAssertEqual(moved.after, window.frame)
        XCTAssertTrue(DisplayConfinementPolicy.contains(window.frame, in: Self.target), "\(window.frame)")
        XCTAssertEqual(window.frame.size, onMain.size)
        XCTAssertEqual(recorder.violations, [])
        XCTAssertFalse(window.isVisible, "the original was replaced; nothing reached the screen")

        // Already on the target: ordered as it is.
        window.orderFront(nil)
        XCTAssertEqual(recorder.events.last?.kind, .placed)
        XCTAssertEqual(recorder.events.last?.after, moved.after)
        XCTAssertEqual(recorder.originals, ["makeKeyAndOrderFront:", "orderFront:"])
    }

    @MainActor
    func testConfineRefusesWithoutAUsableTargetOrRoom() {
        let twin = DisplayConfinementScreen(displayID: 9, name: Self.target.name, frame: Self.main.frame,
                                            visibleFrame: Self.main.visibleFrame, isMain: false)
        let cases: [(String, [DisplayConfinementScreen], String)] = [
            (Self.target.name, [Self.main], "no display is named"),
            (Self.target.name, [Self.main, Self.target, twin], "2 displays are named"),
            (Self.main.name, [Self.main, Self.target], "is the menu-bar display")
        ]
        for (name, screens, expected) in cases {
            let recorder = configure(.confine(displayName: name), screens: screens)
            let window = Self.hiddenWindow()
            window.orderFront(nil)
            XCTAssertEqual(recorder.events.map(\.kind), [.refused], expected)
            XCTAssertTrue(recorder.events.first?.detail.contains(expected) == true, "\(recorder.events)")
            XCTAssertEqual(recorder.originals, [], expected)
            XCTAssertFalse(window.isVisible)
        }

        let recorder = configure(.confine(displayName: Self.target.name), screens: [Self.main, Self.target])
        let large = Self.hiddenWindow(frame: CGRect(x: 0, y: 0, width: 2600, height: 1300))
        large.minSize = CGSize(width: 2500, height: 1200)
        large.orderFront(nil)
        XCTAssertEqual(recorder.events.map(\.kind), [.refused])
        XCTAssertEqual(recorder.events.first?.detail, "the window's minimum size does not fit the target display")
        XCTAssertEqual(recorder.originals, [])
    }

    @MainActor
    func testHiddenWindowsMoveFreelyAndArePlacedOnlyWhenOrdered() {
        let recorder = configure(.confine(displayName: Self.target.name), screens: [Self.main, Self.target])
        let window = Self.hiddenWindow()
        let onMain = CGRect(x: 50, y: 60, width: 300, height: 200)
        window.setFrame(onMain, display: false)
        XCTAssertEqual(window.frame, onMain)
        window.setFrameOrigin(CGPoint(x: 70, y: 80))
        XCTAssertEqual(window.frame.origin, CGPoint(x: 70, y: 80))
        window.setFrameTopLeftPoint(CGPoint(x: 90, y: 500))
        XCTAssertEqual(window.frame.origin, CGPoint(x: 90, y: 300))
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.originals, [])
    }

    @MainActor
    func testSheetsNeedAParentShownOnTheTarget() async {
        let modes: [DisplayConfinementGate.Mode] = [.denyAll(reason: "fixture"), .confine(displayName: Self.target.name)]
        for mode in modes {
            let recorder = configure(mode, screens: [Self.main, Self.target])
            let parent = Self.hiddenWindow()
            let sheet = Self.hiddenWindow()
            let critical = Self.hiddenWindow()
            let ended = expectation(description: "refused sheets end as aborted")
            ended.expectedFulfillmentCount = 2
            parent.beginSheet(sheet) { response in
                XCTAssertEqual(response, .abort)
                ended.fulfill()
            }
            parent.beginCriticalSheet(critical) { response in
                XCTAssertEqual(response, .abort)
                ended.fulfill()
            }
            await fulfillment(of: [ended], timeout: 5)
            XCTAssertEqual(recorder.events.map(\.kind), [.refused, .refused], "\(mode)")
            XCTAssertEqual(recorder.events.map(\.entry),
                           ["beginSheet:completionHandler:", "beginCriticalSheet:completionHandler:"])
            XCTAssertEqual(recorder.originals, [])
            XCTAssertFalse(sheet.isVisible)
            XCTAssertFalse(critical.isVisible)
        }
    }

    @MainActor
    func testModalWindowsAreRefusedAsAborted() {
        let recorder = configure(.denyAll(reason: "fixture"))
        let window = Self.hiddenWindow()
        XCTAssertEqual(NSApplication.shared.runModal(for: window), .abort)
        XCTAssertEqual(recorder.events.map(\.entry), ["runModalForWindow:"])
        XCTAssertEqual(recorder.originals, [])
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testOrderingOffTheMainThreadIsRefused() async {
        let recorder = configure(.inactive)
        let window = Self.hiddenWindow()
        // A detached thread: a synchronous dispatch may run on the main thread.
        let (allowed, wasMain) = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let allowed = DisplayConfinementGate.shared.allowsOrderingIn(window, entry: "fixture-background")
                continuation.resume(returning: (allowed, Thread.isMainThread))
            }
        }
        XCTAssertFalse(wasMain)
        XCTAssertFalse(allowed)
        XCTAssertEqual(recorder.events.map(\.detail), ["window ordering off the main thread"])
    }

    @MainActor
    func testExternalUIIsRefusedWhileTheGateIsActive() {
        let recorder = configure(.denyAll(reason: "fixture"))
        let workspace = NSWorkspace.shared
        let errors = GateRecorder()

        XCTAssertFalse(workspace.open(Self.fixtureURL))
        workspace.open(Self.fixtureURL, configuration: .init()) { application, error in
            XCTAssertNil(application)
            errors.record(original: (error as NSError?)?.localizedDescription ?? "no error")
        }
        workspace.open([Self.fixtureURL], withApplicationAt: Self.fixtureApplication, configuration: .init()) { application, error in
            XCTAssertNil(application)
            errors.record(original: (error as NSError?)?.localizedDescription ?? "no error")
        }
        workspace.openApplication(at: Self.fixtureApplication, configuration: .init()) { application, error in
            XCTAssertNil(application)
            errors.record(original: (error as NSError?)?.localizedDescription ?? "no error")
        }
        workspace.activateFileViewerSelecting([Self.fixtureApplication])
        XCTAssertFalse(workspace.selectFile(nil, inFileViewerRootedAtPath: ""))
        SMAppService.openSystemSettingsLoginItems()

        XCTAssertEqual(recorder.events.map(\.kind), Array(repeating: .externalRefused, count: 7))
        XCTAssertEqual(recorder.events.map(\.entry), [
            "NSWorkspace.openURL:",
            "NSWorkspace.openURL:configuration:completionHandler:",
            "NSWorkspace.openURLs:withApplicationAtURL:configuration:completionHandler:",
            "NSWorkspace.openApplicationAtURL:configuration:completionHandler:",
            "NSWorkspace.activateFileViewerSelectingURLs:",
            "NSWorkspace.selectFile:inFileViewerRootedAtPath:",
            "SMAppService.openSystemSettingsLoginItems"
        ])
        XCTAssertEqual(errors.originals.count, 3)
        XCTAssertTrue(errors.originals.allSatisfy { $0.contains("D106") }, "\(errors.originals)")
        XCTAssertEqual(recorder.violations.count, 7)
        XCTAssertEqual(recorder.originals, [])
    }

    @MainActor
    func testAnInactiveGateCallsEveryOriginalUnchanged() {
        let recorder = configure(.inactive)
        let window = Self.hiddenWindow()
        window.orderFront(nil)
        XCTAssertFalse(NSWorkspace.shared.open(Self.fixtureURL))
        SMAppService.openSystemSettingsLoginItems()
        XCTAssertTrue(DisplayConfinementGate.shared.permitsExternal("fixture"))
        XCTAssertEqual(recorder.originals, ["orderFront:", "NSWorkspace.openURL:", "SMAppService.openSystemSettingsLoginItems"])
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.violations, [])
    }

    // MARK: Helpers

    private func configure(
        _ mode: DisplayConfinementGate.Mode,
        screens: [DisplayConfinementScreen] = [DisplayConfinementPolicyTests.main, DisplayConfinementPolicyTests.target]
    ) -> GateRecorder {
        let recorder = GateRecorder()
        let gate = DisplayConfinementGate.shared
        gate.activate(mode: mode, sink: { recorder.record(event: $0) }, onViolation: { recorder.record(violation: $0) })
        gate.replaceScreensProvider { screens }
        gate.setOriginalCallOverride { recorder.record(original: $0) }
        return recorder
    }

    @MainActor
    private static func hiddenWindow(frame: CGRect = CGRect(x: 10, y: 10, width: 320, height: 240)) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class GateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [DisplayConfinementGate.Event] = []
    private var storedViolations: [DisplayConfinementGate.Event] = []
    private var storedOriginals: [String] = []

    var events: [DisplayConfinementGate.Event] { locked { storedEvents } }
    var violations: [DisplayConfinementGate.Event] { locked { storedViolations } }
    var originals: [String] { locked { storedOriginals } }

    func record(event: DisplayConfinementGate.Event) { locked { storedEvents.append(event) } }
    func record(violation: DisplayConfinementGate.Event) { locked { storedViolations.append(violation) } }
    func record(original: String) { locked { storedOriginals.append(original) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
