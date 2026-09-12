import AppKit
import ApplicationServices
import CoreGraphics
import XCTest

/// A deliberately opt-in smoke test for the installed application.
///
/// SwiftPM's XCTest target is not an Xcode UI-test bundle, so this test uses
/// the public macOS Accessibility API instead of pretending that an
/// `XCUIApplication` target exists. It never asks for Accessibility access,
/// clicks by coordinates, or touches App Store/Terminal/System Settings.
final class RealMacUIAccessibilitySmokeTests: XCTestCase {
    private static let defaultBundlePath = "/Applications/存储清理助手.app"
    private static let defaultBundleIdentifier = "com.local.StorageCleanerMac"

    private struct VisualElementFrame {
        let role: String
        let label: String
        let frame: CGRect
    }

    func testInstalledMainWindowIsAccessibleWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_UI_TESTS"] == "1" else {
            throw XCTSkip(
                "Opt-in only: set STORAGE_CLEANER_RUN_UI_TESTS=1 to inspect the installed app."
            )
        }

        try requireUnlockedConsole()
        guard AXIsProcessTrusted() else {
            throw XCTSkip(
                "Accessibility permission is not granted to this test process; no prompt was requested."
            )
        }

        let bundleURL = try validatedBundleURL()
        let (application, launchedByTest) = try await launchIfNeeded(at: bundleURL)
        defer {
            if launchedByTest {
                application.terminate()
            }
        }

        let window = try await waitForMainWindow(of: application)
        let title = accessibilityString(window, attribute: kAXTitleAttribute)
            ?? accessibilityString(window, attribute: kAXDescriptionAttribute)
        XCTAssertFalse(
            title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
            "The real main window must expose an accessibility title or description."
        )
        XCTAssertEqual(
            accessibilityString(window, attribute: kAXRoleAttribute),
            kAXWindowRole as String
        )
        XCTAssertTrue(
            containsBasicControl(in: window),
            "The real main window must expose at least one accessible basic control."
        )
        let overlaps = overlappingSiblingVisualElements(in: window)
        XCTAssertTrue(
            overlaps.isEmpty,
            "Sibling labels or controls overlap in the real window:\n"
                + overlaps.prefix(12).joined(separator: "\n")
        )
    }

    private func requireUnlockedConsole() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            throw XCTSkip("The console session state is unavailable; refusing to launch UI smoke.")
        }
        if (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue != true {
            throw XCTSkip("No unlocked console user session is available; refusing to launch UI smoke.")
        }
        if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
            throw XCTSkip("The console is locked; unlock macOS before running the UI smoke test.")
        }
    }

    private func validatedBundleURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_UI_APP_PATH"]
            ?? Self.defaultBundlePath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isDirectory,
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == expectedBundleIdentifier else {
            throw XCTSkip(
                "Target app bundle is missing or has an unexpected bundle identifier: \(url.path)"
            )
        }
        return url
    }

    private func launchIfNeeded(at bundleURL: URL) async throws -> (NSRunningApplication, Bool) {
        if let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: expectedBundleIdentifier
        ).first(where: { !$0.isTerminated }) {
            return (existing, false)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let application: NSRunningApplication = try await withCheckedThrowingContinuation {
            continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
                application,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "StorageCleanerMac.RealMacUIAccessibilitySmokeTests",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "NSWorkspace returned no application"]
                        )
                    )
                }
            }
        }
        return (application, true)
    }

    private func waitForMainWindow(of application: NSRunningApplication) async throws -> AXUIElement {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        for _ in 0..<40 {
            if let window = mainWindow(from: root) {
                return window
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw XCTSkip("The launched app did not expose an accessible main window within 10 seconds.")
    }

    private func mainWindow(from application: AXUIElement) -> AXUIElement? {
        if let focused = accessibilityElement(application, attribute: kAXFocusedWindowAttribute),
           accessibilityString(focused, attribute: kAXRoleAttribute) == kAXWindowRole as String {
            return focused
        }
        guard let windows = accessibilityElements(application, attribute: kAXWindowsAttribute) else {
            return nil
        }
        return windows.first {
            accessibilityString($0, attribute: kAXRoleAttribute) == kAXWindowRole as String
        }
    }

    private func containsBasicControl(in root: AXUIElement) -> Bool {
        let acceptedRoles: Set<String> = [
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXPopUpButtonRole as String,
            kAXTextFieldRole as String,
            kAXStaticTextRole as String
        ]
        var queue = [root]
        var visited = 0
        while !queue.isEmpty && visited < 500 {
            let element = queue.removeFirst()
            visited += 1
            if let role = accessibilityString(element, attribute: kAXRoleAttribute),
               acceptedRoles.contains(role) {
                return true
            }
            if let children = accessibilityElements(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: children)
            }
        }
        return false
    }

    private var expectedBundleIdentifier: String {
        ProcessInfo.processInfo.environment["STORAGE_CLEANER_UI_BUNDLE_IDENTIFIER"]
            ?? Self.defaultBundleIdentifier
    }

    /// Compare only visual siblings. Parent/child frames intentionally overlap,
    /// while sibling text, icons and controls should never occupy the same pixels.
    private func overlappingSiblingVisualElements(in root: AXUIElement) -> [String] {
        let visualRoles: Set<String> = [
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXImageRole as String,
            kAXPopUpButtonRole as String,
            kAXRadioButtonRole as String,
            kAXStaticTextRole as String,
            kAXTextFieldRole as String
        ]
        var queue = [root]
        var visited = 0
        var findings: [String] = []

        while !queue.isEmpty && visited < 1_500 && findings.count < 24 {
            let parent = queue.removeFirst()
            visited += 1
            guard let children = accessibilityElements(parent, attribute: kAXChildrenAttribute) else {
                continue
            }
            queue.append(contentsOf: children)

            let visualChildren = children.compactMap { child -> VisualElementFrame? in
                guard let role = accessibilityString(child, attribute: kAXRoleAttribute),
                      visualRoles.contains(role),
                      let frame = accessibilityFrame(child),
                      frame.width > 1,
                      frame.height > 1 else { return nil }
                let label = accessibilityString(child, attribute: kAXTitleAttribute)
                    ?? accessibilityString(child, attribute: kAXDescriptionAttribute)
                    ?? accessibilityString(child, attribute: kAXValueAttribute)
                    ?? role
                return VisualElementFrame(role: role, label: label, frame: frame)
            }

            for firstIndex in visualChildren.indices {
                for secondIndex in visualChildren.indices where secondIndex > firstIndex {
                    let first = visualChildren[firstIndex]
                    let second = visualChildren[secondIndex]
                    let intersection = first.frame.intersection(second.frame)
                    guard !intersection.isNull,
                          intersection.width > 1.5,
                          intersection.height > 1.5 else { continue }
                    findings.append(
                        "\(first.role) ‘\(first.label)’ \(first.frame) overlaps "
                            + "\(second.role) ‘\(second.label)’ \(second.frame)"
                    )
                }
            }
        }
        return findings
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionReference = accessibilityValue(
            element,
            attribute: kAXPositionAttribute
        ),
        let sizeReference = accessibilityValue(
            element,
            attribute: kAXSizeAttribute
        ),
        CFGetTypeID(positionReference) == AXValueGetTypeID(),
        CFGetTypeID(sizeReference) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionReference as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeReference as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func accessibilityString(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        accessibilityValue(element, attribute: attribute) as? String
    }

    private func accessibilityElement(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        guard let value = accessibilityValue(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func accessibilityElements(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement]? {
        accessibilityValue(element, attribute: attribute) as? [AXUIElement]
    }

    private func accessibilityValue(
        _ element: AXUIElement,
        attribute: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
