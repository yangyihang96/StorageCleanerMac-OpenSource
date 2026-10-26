import AppKit
import Darwin

/// D106: the Beta's read-only UI acceptance launch.
///
/// `--acceptance-display <name> --acceptance-log <path>` starts the app with
/// every window kept on that display before it is shown
/// (`DisplayConfinementGate`). It fails closed: a missing or ambiguous
/// display, the menu-bar display, an existing log file, another running copy,
/// unverified Full Disk Access or any other launch switch ends the process
/// before a window, status item, store or helper connection exists. Any
/// argument that starts with `--acceptance` asks for this mode, so a
/// misspelt or partial request ends the process the same way instead of
/// starting a normal session on the menu-bar display. A window
/// that cannot be placed on the display stays hidden; one seen off it, or the
/// display going away, ends the session. UI that another
/// process would show (opening apps or URLs, Finder, System Settings,
/// notifications, permission and password prompts, login items) is refused,
/// because nothing in this process can place it.
///
/// The session also leaves out what would act outside the window under test:
/// the menu-bar status item (the system draws it in every display's menu
/// bar), the fan and power helper (no connection, so quitting writes nothing
/// to the SMC or power settings), Sparkle and third-party app update checks,
/// the first-run and return-to-app folder access probes (macOS shows its
/// permission prompts on the menu-bar display), and launch-time deletion of
/// expired app data (browser-history recovery backups, privacy snapshots,
/// benchmark temporaries). The next normal launch runs all of them; nothing
/// is turned off for it. Release builds never enter this mode.
enum AcceptanceLaunch {
    static let displayArgument = "--acceptance-display"
    static let logArgument = "--acceptance-log"
    /// Every argument with this prefix is read as part of an acceptance request.
    static let argumentPrefix = "--acceptance"
    /// Opens the monitoring panel on the acceptance display after launch.
    static let openPanelArgument = "--open-menu-bar-panel"

    enum ExitCode {
        static let usage: Int32 = 64
        static let cannotCreateLog: Int32 = 73
        static let anotherCopyRunning: Int32 = 75
        static let permissionsUnverified: Int32 = 77
        static let displayUnavailable: Int32 = 78
    }

    struct Request: Equatable, Sendable {
        let displayName: String
        let logPath: String
        let opensPanel: Bool
    }

    enum RequestError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingValue(String)
        case repeated(String)
        case missingLog
        case relativeLogPath
        case unsupportedArgument(String)

        var description: String {
            switch self {
            case .missingValue(let argument): "\(argument) needs a value"
            case .repeated(let argument): "\(argument) is given more than once"
            case .missingLog: "\(AcceptanceLaunch.logArgument) <absolute path> is required"
            case .relativeLogPath: "the log path must be absolute"
            case .unsupportedArgument(let argument): "\(argument) is not allowed in an acceptance launch"
            }
        }
    }

    /// True for the whole process when the Beta was started for acceptance.
    static let isActive: Bool = {
#if STORAGE_CLEANER_BETA
        asksForAcceptance(ProcessInfo.processInfo.arguments)
#else
        false
#endif
    }()

    /// nil for a normal launch. Next to its own switches an acceptance launch
    /// accepts only volatile defaults overrides (`-Key value`) and
    /// LaunchServices' `-psn_` argument, so no diagnostic, capture or
    /// hardware switch can ride along. The app finds those switches with
    /// `arguments.contains` wherever they stand, so every `--` argument is
    /// checked on its own first, and a defaults value cannot be one: a switch
    /// given as `-Key --switch` is refused too (D106-R3).
    static func request(in arguments: [String]) -> Result<Request?, RequestError> {
        guard asksForAcceptance(arguments) else { return .success(nil) }
        let arguments = Array(arguments.dropFirst())
        let ownSwitches: Set<String> = [displayArgument, logArgument, openPanelArgument]
        if let other = arguments.first(where: { $0.hasPrefix("--") && !ownSwitches.contains($0) }) {
            return .failure(.unsupportedArgument(other))
        }
        var displayName: String?
        var logPath: String?
        var opensPanel = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case displayArgument, logArgument:
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    return .failure(.missingValue(argument))
                }
                let value = arguments[index + 1]
                if argument == displayArgument {
                    guard displayName == nil else { return .failure(.repeated(argument)) }
                    displayName = value
                } else {
                    guard logPath == nil else { return .failure(.repeated(argument)) }
                    logPath = value
                }
                index += 2
            case openPanelArgument:
                guard !opensPanel else { return .failure(.repeated(argument)) }
                opensPanel = true
                index += 1
            default:
                if argument.hasPrefix("-psn_") {
                    index += 1
                } else if argument.count > 1, argument.hasPrefix("-"), !argument.hasPrefix("--") {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        return .failure(.missingValue(argument))
                    }
                    index += 2
                } else {
                    return .failure(.unsupportedArgument(argument))
                }
            }
        }
        guard let displayName else { return .failure(.missingValue(displayArgument)) }
        guard let logPath else { return .failure(.missingLog) }
        guard logPath.hasPrefix("/") else { return .failure(.relativeLogPath) }
        return .success(Request(displayName: displayName, logPath: logPath, opensPanel: opensPanel))
    }

    /// argv (with the executable first) names any acceptance switch.
    static func asksForAcceptance(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix(argumentPrefix) }
    }

#if STORAGE_CLEANER_BETA
    /// The first statement of App.init. Returns at once for a normal launch;
    /// an acceptance launch returns only with the gate confining windows to
    /// its display, and exits otherwise.
    @MainActor
    static func configureOrExit() {
        let request: Request
        switch Self.request(in: ProcessInfo.processInfo.arguments) {
        case .success(nil): return
        case .success(let value?): request = value
        case .failure(let error): exitBeforeLaunch(error.description, code: ExitCode.usage)
        }
        // Never activate or hand over to another copy: its windows are not confined.
        if let identifier = Bundle.main.bundleIdentifier {
            let current = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != current && !$0.isTerminated }
            if !others.isEmpty {
                exitBeforeLaunch("another copy of \(identifier) is running", code: ExitCode.anotherCopyRunning)
            }
        }
        guard let log = AcceptanceDisplayLog(path: request.logPath) else {
            exitBeforeLaunch("cannot create a new log file at \(request.logPath)", code: ExitCode.cannotCreateLog)
        }
        let target: DisplayConfinementScreen
        switch DisplayConfinementPolicy.resolveTarget(named: request.displayName, in: DisplayConfinementScreen.current()) {
        case .success(let resolved):
            target = resolved
        case .failure(let error):
            log.record(kind: "display-unavailable", detail: error.description)
            exitBeforeLaunch(error.description, code: ExitCode.displayUnavailable)
        }
        // With Full Disk Access every protected folder reads without asking;
        // without it a scan makes macOS ask on the menu-bar display. The probe
        // only lists folders that never prompt (Safari, Mail, Messages).
        let access = ScanReadinessService.fullDiskAccessState()
        guard access == .verified else {
            let detail = "Full Disk Access is \(access == .unknown ? "unknown" : "not verified") for this build"
            log.record(kind: "permissions-unverified", detail: detail)
            exitBeforeLaunch(detail, code: ExitCode.permissionsUnverified)
        }
        let displayName = request.displayName
        DisplayConfinementGate.shared.activate(
            mode: .confine(displayName: displayName),
            sink: { log.record($0) },
            onViolation: { event in
                // A refused window or outside UI stays hidden and is logged.
                // A window seen off the display, or a display that is gone,
                // ends the session: nothing it shows after that is evidence.
                switch event.kind {
                case .violation:
                    Task { @MainActor in NSApplication.shared.terminate(nil) }
                case .refused:
                    Task { @MainActor in
                        guard case .failure = DisplayConfinementPolicy.resolveTarget(
                            named: displayName, in: DisplayConfinementScreen.current()
                        ) else { return }
                        NSApplication.shared.terminate(nil)
                    }
                default:
                    return
                }
            }
        )
        log.record(
            kind: DisplayConfinementGate.Event.Kind.installed.rawValue,
            detail: "display \(target.displayID) \"\(target.name)\" frame \(DisplayConfinementLogFormat.numbers(target.frame))"
        )
    }

    private static func exitBeforeLaunch(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("StorageCleanerMac acceptance launch refused: \(message)\n".utf8))
        exit(code)
    }
#endif
}

enum DisplayConfinementLogFormat {
    static func numbers(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map(Double.init)
    }
}

/// D106: JSON lines for one acceptance session, one per confinement
/// decision with the frame before and after. Always a new file (an existing
/// one is never appended to or replaced), readable by its owner only.
final class AcceptanceDisplayLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init?(path: String) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func record(_ event: DisplayConfinementGate.Event) {
        var fields: [String: Any] = ["kind": event.kind.rawValue, "entry": event.entry, "window": event.window]
        if let before = event.before { fields["before"] = DisplayConfinementLogFormat.numbers(before) }
        if let after = event.after { fields["after"] = DisplayConfinementLogFormat.numbers(after) }
        if !event.detail.isEmpty { fields["detail"] = event.detail }
        write(fields)
    }

    func record(kind: String, detail: String) {
        write(["kind": kind, "detail": detail])
    }

    private func write(_ fields: [String: Any]) {
        var fields = fields
        fields["time"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
        guard var line = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: line)
    }
}
