import AppKit
import CoreGraphics
import CoreMediaIO
import Foundation

/// Situations in which a reminder waits instead of appearing (CleanMyMac
/// `AlertEnvironmentFactor`: `mainAppOpen`, `menuAppOpen`, `fullScreenModeOn`,
/// `cameraActive`, `screenRecordingActive`, `doNotDisturbModeEnabled`).
/// CleanMyMac's split between “declined” and “postponed” factors is unknown,
/// so every factor postpones: the reminder appears once none is active.
/// Screen recording and Focus have no public API and are not observed.
enum AlertEnvironmentFactor: String, CaseIterable, Sendable {
    case mainAppOpen
    case menuAppOpen
    case fullScreenModeOn
    case cameraActive
}

@MainActor
enum AlertEnvironmentWatcher {
    static func activeFactors() -> Set<AlertEnvironmentFactor> {
        var factors = Set<AlertEnvironmentFactor>()
        if isMainWindowInUse() { factors.insert(.mainAppOpen) }
        if NSApp.windows.contains(where: { $0 is MenuBarStatusPanel && $0.isVisible }) { factors.insert(.menuAppOpen) }
        if isFrontmostApplicationFullScreen() { factors.insert(.fullScreenModeOn) }
        if isAnyCameraRunning() { factors.insert(.cameraActive) }
        return factors
    }

    /// The person is working in this app's main window right now.
    private static func isMainWindowInUse() -> Bool {
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { window in
            window.isVisible && window.isKeyWindow && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }

    /// The frontmost app has a normal-level window covering a whole display,
    /// as a full-screen space or a presentation does.
    private static func isFrontmostApplicationFullScreen() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmost.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return false }
            return displays.contains { $0.equalTo(bounds) }
        }
    }

    /// CoreMediaIO: some process is using a camera (a call or a recording).
    private static func isAnyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, runningSize, &runningSize, &running) == 0,
               running != 0 {
                return true
            }
        }
        return false
    }
}
