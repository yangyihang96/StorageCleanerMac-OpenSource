import AppKit
import CoreGraphics
import Foundation

// Run only on the affected Mac: swift script/mini_window_display_diagnostics.swift
// Reads display geometry; no screenshots, serial numbers, file paths, process
// inventory, network requests, permissions, helper registration or hardware writes.
@MainActor
func emitDisplayDiagnostics() throws {
    func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.origin.x), "y": Double(r.origin.y),
         "width": Double(r.width), "height": Double(r.height)]
    }
    let displays: [[String: Any]] = NSScreen.screens.enumerated().map { index, screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return ["index": index, "framePoints": rect(screen.frame),
                "visibleFramePoints": rect(screen.visibleFrame),
                "backingScaleFactor": screen.backingScaleFactor,
                "rotationDegrees": number.map { CGDisplayRotation(CGDirectDisplayID($0.uint32Value)) } ?? 0]
    }
    let result: [String: Any] = ["collectedAt": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "coordinateSystem": "AppKit logical points; no display spanning", "displays": displays]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
try emitDisplayDiagnostics()
