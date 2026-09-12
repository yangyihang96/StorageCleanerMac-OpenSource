# Menu Bar Current-Space Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the process-lifetime `NSPopover` with a short-lived nonactivating `NSPanel` session that opens on the Space and display where the status item was clicked without reintroducing the compact/advanced picker dismissal bug.

**Architecture:** `MenuBarStatusController` remains the status-item and refresh owner. New focused AppKit types own window policy, geometry, event classification, and teardown; SwiftUI panel content remains unchanged apart from the root name and resize callback. The implementation uses only public AppKit APIs and keeps one session at most.

**Tech Stack:** Swift 6, AppKit `NSPanel`, SwiftUI `NSHostingController`, Combine, XCTest, macOS 14–26 public APIs.

---

### Task 1: Define and test panel placement

**Files:**
- Create: `Sources/StorageCleanerMac/Support/MenuBarPanelPlacement.swift`
- Create: `Tests/StorageCleanerMacTests/MenuBarPanelPlacementTests.swift`

- [ ] **Step 1: Write the failing geometry tests**

```swift
import AppKit
import XCTest
@testable import StorageCleanerMac

final class MenuBarPanelPlacementTests: XCTestCase {
    func testFrameCentersBelowAnchorAndStaysInsideVisibleFrame() {
        let frame = MenuBarPanelPlacement.frame(
            anchor: NSRect(x: 900, y: 875, width: 24, height: 24),
            contentSize: NSSize(width: 430, height: 560),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 900),
            margin: 8,
            gap: 4
        )
        XCTAssertEqual(frame.maxX, 992, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 871, accuracy: 0.001)
    }

    func testFrameSupportsNegativeDisplayCoordinates() {
        let visible = NSRect(x: -1440, y: -120, width: 1440, height: 900)
        let frame = MenuBarPanelPlacement.frame(
            anchor: NSRect(x: -80, y: 756, width: 22, height: 22),
            contentSize: NSSize(width: 360, height: 300),
            visibleFrame: visible,
            margin: 8,
            gap: 4
        )
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testAdvancedResizeKeepsTheSameTopAnchor() {
        let anchor = NSRect(x: 400, y: 875, width: 24, height: 24)
        let visible = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let compact = MenuBarPanelPlacement.frame(anchor: anchor, contentSize: .init(width: 360, height: 300), visibleFrame: visible)
        let advanced = MenuBarPanelPlacement.frame(anchor: anchor, contentSize: .init(width: 430, height: 560), visibleFrame: visible)
        XCTAssertEqual(compact.maxY, advanced.maxY, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `./script/test.sh --filter MenuBarPanelPlacementTests`

Expected: compilation fails because `MenuBarPanelPlacement` does not exist.

- [ ] **Step 3: Implement the pure placement type**

```swift
import AppKit

enum MenuBarPanelPlacement {
    static func frame(
        anchor: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = 8,
        gap: CGFloat = 4
    ) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(contentSize.width, bounds.width)
        let height = min(contentSize.height, bounds.height)
        let preferredX = anchor.midX - width / 2
        let x = min(max(preferredX, bounds.minX), bounds.maxX - width)
        let preferredY = anchor.minY - gap - height
        let y = min(max(preferredY, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
```

- [ ] **Step 4: Run the focused tests**

Run: `./script/test.sh --filter MenuBarPanelPlacementTests`

Expected: 3 tests pass.

- [ ] **Step 5: Commit the geometry unit**

```bash
git add Sources/StorageCleanerMac/Support/MenuBarPanelPlacement.swift Tests/StorageCleanerMacTests/MenuBarPanelPlacementTests.swift
git commit -m "feat(menu): add current-display panel placement"
```

### Task 2: Add a public-API panel policy

**Files:**
- Create: `Sources/StorageCleanerMac/Support/MenuBarStatusPanel.swift`
- Create: `Tests/StorageCleanerMacTests/MenuBarStatusPanelTests.swift`

- [ ] **Step 1: Write failing window-policy tests**

```swift
import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MenuBarStatusPanelTests: XCTestCase {
    func testPanelUsesCurrentSpacePolicyWithoutJoiningEverySpace() {
        let panel = MenuBarStatusPanel(contentRect: .zero)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `./script/test.sh --filter MenuBarStatusPanelTests`

Expected: compilation fails because `MenuBarStatusPanel` does not exist.

- [ ] **Step 3: Implement the panel subclass**

```swift
import AppKit

final class MenuBarStatusPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]
        level = .popUpMenu
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 4: Run the focused test**

Run: `./script/test.sh --filter MenuBarStatusPanelTests`

Expected: the policy test passes.

- [ ] **Step 5: Commit the panel unit**

```bash
git add Sources/StorageCleanerMac/Support/MenuBarStatusPanel.swift Tests/StorageCleanerMacTests/MenuBarStatusPanelTests.swift
git commit -m "feat(menu): define transient status panel policy"
```

### Task 3: Implement event ownership and idempotent session teardown

**Files:**
- Create: `Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift`
- Create: `Tests/StorageCleanerMacTests/MenuBarPanelSessionTests.swift`

- [ ] **Step 1: Write failing event-classification and teardown tests**

```swift
@MainActor
func testSessionTreatsChildWindowAndTrackedMenuAsInternalInteraction() {
    let panel = MenuBarStatusPanel(contentRect: .init(x: 0, y: 0, width: 360, height: 300))
    let child = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    panel.addChildWindow(child, ordered: .above)
    let session = MenuBarPanelSession.testing(panel: panel)
    XCTAssertTrue(session.owns(window: panel))
    XCTAssertTrue(session.owns(window: child))
    session.setMenuTracking(true)
    XCTAssertFalse(session.shouldClose(for: nil))
}

@MainActor
func testSessionTeardownIsIdempotent() {
    let session = MenuBarPanelSession.testing()
    session.teardown()
    session.teardown()
    XCTAssertTrue(session.isTornDown)
    XCTAssertEqual(session.activeMonitorCount, 0)
    XCTAssertEqual(session.activeObserverCount, 0)
}
```

- [ ] **Step 2: Run the test and verify the new API is missing**

Run: `./script/test.sh --filter MenuBarPanelSessionTests`

Expected: compilation fails on `MenuBarPanelSession`.

- [ ] **Step 3: Implement the session around explicit dependencies**

Create `MenuBarPanelSession` as an `@MainActor final class` that owns exactly one `MenuBarStatusPanel`, one `NSHostingController<AnyView>`, local mouse/key monitors, a global mouse monitor, Space/screen/menu notification tokens, the status button window, and an `onClose` closure. Its public surface must be:

```swift
@MainActor
final class MenuBarPanelSession {
    let panel: MenuBarStatusPanel
    private(set) var isTornDown = false

    func show(anchor: NSRect, screen: NSScreen, contentSize: NSSize)
    func resize(contentSize: NSSize)
    func owns(window: NSWindow?) -> Bool
    func setMenuTracking(_ value: Bool)
    func shouldClose(for window: NSWindow?) -> Bool
    func teardown()
}
```

Add internal test factories `testing(panel:)` and `testing()` plus read-only `activeMonitorCount` and `activeObserverCount`; compile them only for Debug/test builds and implement them through the same teardown path as production. `owns(window:)` must walk `parent` and `childWindows`; menu tracking suppresses only outside-click dismissal. `teardown()` must remove all `NSEvent` monitors and `NotificationCenter` observers, order out and close the panel, clear the content view/controller, release closures, and call `onClose` once. Listen to `NSWorkspace.activeSpaceDidChangeNotification`, `NSApplication.didChangeScreenParametersNotification`, `NSMenu.didBeginTrackingNotification`, and `NSMenu.didEndTrackingNotification`. Do not test private window class names and do not close primarily from `windowDidResignKey`.

- [ ] **Step 4: Run session and interaction tests**

Run: `./script/test.sh --filter MenuBarPanelSessionTests`

Expected: event ownership and repeated teardown pass.

- [ ] **Step 5: Commit the session**

```bash
git add Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift Tests/StorageCleanerMacTests/MenuBarPanelSessionTests.swift
git commit -m "feat(menu): add short-lived panel session"
```

### Task 4: Replace `NSPopover` in the controller

**Files:**
- Modify: `Sources/StorageCleanerMac/Support/MenuBarStatusController.swift:5-173`
- Create: `Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift`
- Modify: `Sources/StorageCleanerMac/Views/MenuBarStatusView.swift`
- Modify: `Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift`
- Modify: `Tests/StorageCleanerMacTests/MenuBarPanelInteractionTests.swift`
- Modify: `Tests/StorageCleanerMacTests/SystemMonitorServiceTests.swift`

- [ ] **Step 1: Change source-policy tests to require the panel session**

Update the existing source assertions so they require `MenuBarPanelSession`, reject `NSPopover`, retain `.pickerStyle(.segmented)`, reject nested `Menu`, and assert that selection invokes a resize callback without dismissing the inline settings surface.

- [ ] **Step 2: Run the menu tests and verify they fail against the popover controller**

Run: `./script/test.sh --filter MenuBarPanelInteractionTests`

Expected: assertions fail because the controller still contains `NSPopover`.

- [ ] **Step 3: Refactor the controller to one optional session**

Replace `private let popover` with `private var panelSession: MenuBarPanelSession?`. Rename `togglePopover`, `presentPopover`, `dismissPopover`, `applyPopoverSize`, and `MenuBarStatusPopoverRoot` to panel terminology. On each status-button mouse-up:

```swift
if let session = panelSession, session.panel.isVisible, session.panel.isOnActiveSpace {
    session.teardown()
    return
}
panelSession?.teardown()
presentPanel(from: sender)
```

`presentPanel(from:)` must convert the button bounds through its window to screen coordinates, prefer `button.window?.screen`, fall back to the screen containing the anchor, then the mouse screen, then `NSScreen.main`. Create a fresh session and capture it weakly in `onClose`; status-item highlight must be cleared only for the current session. `selectPanelMode` must persist immediately and call `session.resize(contentSize:)` without rebuilding or closing the settings UI.

- [ ] **Step 4: Replace all explicit dismissal callers**

Change compact/advanced footer actions and main-window opening paths from `dismissPopover()` to `dismissPanel()`. Keep the status button configured with `.leftMouseUp` only so mouse-down and mouse-up cannot double-toggle.

- [ ] **Step 5: Run all menu-focused tests**

Run: `./script/test.sh --filter MenuBarPanel`

Expected: placement, policy, session, inline mode selection, and controller source tests pass.

- [ ] **Step 6: Commit the controller migration**

```bash
git add Sources/StorageCleanerMac/Support/MenuBarStatusController.swift Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift Sources/StorageCleanerMac/Views/MenuBarStatusView.swift Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift Tests/StorageCleanerMacTests/MenuBarPanelInteractionTests.swift Tests/StorageCleanerMacTests/SystemMonitorServiceTests.swift
git commit -m "fix(menu): open status panel on the active Space"
```

### Task 5: Real Space and lifecycle verification

**Files:**
- Create: `release/validation/menu-panel-v1.5.0.md`

- [ ] **Step 1: Build the development app with verification**

Run: `APP_VERSION=1.5.0 APP_BUILD=$(date +%Y%m%d%H%M) ./script/build_and_run.sh --verify`

Expected: build, bundle metadata, signing verification, and launch succeed.

- [ ] **Step 2: Verify two Spaces and full-screen behavior**

Record desktop 1, desktop 2, another app's full-screen Space, compact mode, advanced mode, Escape, outside click, sheet/menu interaction, and status-item second-click close. Confirm the panel opens on the currently clicked Space and does not remain on the old Space.

- [ ] **Step 3: Verify display placement**

Repeat on the main display and every connected display, including negative-coordinate or vertically arranged displays. Confirm the app footer identifies `存储清理助手`, not LemonMonitor or iStat Menus.

- [ ] **Step 4: Run a 100-cycle open/close soak**

Use the existing debug launch hook updated to drive the real status button session. Compare `NSApp.windows`, thread count, resident memory, and idle CPU before and after; no panel, hosting controller, observer, or event monitor may accumulate.

- [ ] **Step 5: Commit the validation record**

```bash
git add release/validation/menu-panel-v1.5.0.md
git commit -m "test(menu): record active Space validation"
```
