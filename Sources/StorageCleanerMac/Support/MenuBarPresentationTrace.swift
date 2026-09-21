import AppKit
import SwiftUI

/// Opt-in local audit. Draw acknowledgements are deliberately not labelled as
/// compositor presentation or physical display latency.
@MainActor
enum MenuBarPresentationTrace {
    static let outputPath: String? = {
#if DEBUG || STORAGE_CLEANER_BETA
        let prefix = "--menu-bar-performance-audit="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }.flatMap { $0.hasPrefix("/") ? $0 : nil }
#else
        return nil
#endif
    }()
    static var enabled: Bool { outputPath != nil }
    private static var pending: [String: (time: Double, event: Double?)] = [:]
    private static var count = 0
    private static var acceptingEvents = false
    private static let writer = DispatchQueue(label: "MenuBarPerformanceEvidence", qos: .utility)

    static func startPresentation(event: NSEvent?) {
        acceptingEvents = true
        begin("presentation", event: event)
    }

    static func begin(_ key: String, event: NSEvent? = nil) {
        guard enabled, acceptingEvents else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let timestamp = event?.timestamp
        pending[key] = (now, timestamp.flatMap { $0 <= now && now - $0 < 1 ? $0 : nil })
    }

    static func discardPendingDraws() {
        acceptingEvents = false
        pending.removeAll(keepingCapacity: true)
    }

    static func drew(_ key: String, window: NSWindow?) {
        guard let path = outputPath, let window, window.isVisible,
              let start = pending.removeValue(forKey: key), count < 1000 else { return }
        count += 1
        let now = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = ["kind": "appkit_draw_ack", "target": key,
            "startedUptime": start.time, "drawUptime": now,
            "elapsedMs": (now - start.time) * 1000,
            "window": window.windowNumber,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"]
        if let event = start.event { record["inputUptime"] = event; record["inputToDrawMs"] = (now - event) * 1000 }
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let payload = data
        writer.async {
            if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: payload) } catch { }
        }
    }
}

struct MenuBarPresentationProbe: NSViewRepresentable {
    let key: String
    var revision: UInt64 = 0
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.key = key
        view.needsDisplay = true
    }
    final class Probe: NSView {
        var key = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { MenuBarPresentationTrace.drew(key, window: window) }
    }
}
