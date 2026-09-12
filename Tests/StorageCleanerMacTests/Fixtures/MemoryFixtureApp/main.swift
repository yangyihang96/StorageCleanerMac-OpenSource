import AppKit
import Darwin
import Foundation

private enum TerminationMode: String {
    case allow
    case delay
    case refuse
    case unsaved
}

private struct FixtureOptions {
    var allocationMiB = 32
    var terminationMode = TerminationMode.allow
    var delaySeconds = 2.0
    var exitAfterSeconds: Double?
    var relaunchAfterExit = false
    var statusFile: String?

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--allocate-mib":
                allocationMiB = min(512, max(0, Int(value ?? "") ?? allocationMiB))
                index += 2
            case "--termination":
                terminationMode = TerminationMode(rawValue: value ?? "") ?? .allow
                index += 2
            case "--delay-seconds":
                delaySeconds = min(30, max(0, Double(value ?? "") ?? delaySeconds))
                index += 2
            case "--exit-after-seconds":
                exitAfterSeconds = min(60, max(0.1, Double(value ?? "") ?? 1))
                index += 2
            case "--status-file":
                statusFile = value
                index += 2
            case "--relaunch-after-exit":
                relaunchAfterExit = true
                index += 1
            default:
                index += 1
            }
        }
    }
}

@MainActor
private final class MemoryFixtureDelegate: NSObject, NSApplicationDelegate {
    private let options: FixtureOptions
    private var allocation = Data()
    private var window: NSWindow?
    private var events: [String] = []

    init(options: FixtureOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        allocateMemory()
        showWindow()
        writeStatus("ready")

        if let seconds = options.exitAfterSeconds {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if options.relaunchAfterExit {
                    relaunch()
                }
                writeStatus("suddenExit")
                Darwin.exit(42)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch options.terminationMode {
        case .allow:
            writeStatus("terminationAllowed")
            return .terminateNow
        case .delay:
            writeStatus("terminationDelayed")
            Task { @MainActor [weak sender] in
                try? await Task.sleep(for: .seconds(options.delaySeconds))
                sender?.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .refuse:
            writeStatus("terminationRefused")
            return .terminateCancel
        case .unsaved:
            writeStatus("unsavedDocument")
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        writeStatus("terminated")
    }

    private func allocateMemory() {
        let byteCount = options.allocationMiB * 1_024 * 1_024
        guard byteCount > 0 else { return }
        allocation = Data(repeating: 0xA5, count: byteCount)
    }

    private func showWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Memory Fixture App"
        let label = NSTextField(labelWithString: "StorageCleanerMac memory safety fixture\nMode: \(options.terminationMode.rawValue) · Allocation: \(options.allocationMiB) MiB")
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 20, y: 45, width: 340, height: 50)
        panel.contentView?.addSubview(label)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        var arguments = [
            "--allocate-mib", String(options.allocationMiB),
            "--termination", options.terminationMode.rawValue,
            "--delay-seconds", String(options.delaySeconds),
        ]
        if let statusFile = options.statusFile {
            arguments += ["--status-file", statusFile]
        }
        process.arguments = arguments
        try? process.run()
    }

    private func writeStatus(_ event: String) {
        guard let statusFile = options.statusFile else { return }
        events.append(event)
        let payload: [String: Any] = [
            "event": event,
            "events": events,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "terminationMode": options.terminationMode.rawValue,
            "allocationMiB": options.allocationMiB,
            "timestamp": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: statusFile), options: .atomic)
    }
}

@main
private enum MemoryFixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MemoryFixtureDelegate(
            options: FixtureOptions(arguments: ProcessInfo.processInfo.arguments)
        )
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
