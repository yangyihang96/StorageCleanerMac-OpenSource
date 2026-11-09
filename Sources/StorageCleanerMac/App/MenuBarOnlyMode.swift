import AppKit
import SwiftUI

/// D256: whether quitting closes only the main program and keeps the
/// menu-bar panel running in this process (General settings, on by default).
enum AppQuitPreferences {
    static let keepsMenuBarPanelKey = "app.keepMenuBarPanelAfterQuit.v1"

    static func keepsMenuBarPanelAfterQuit(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepsMenuBarPanelKey) as? Bool ?? true
    }
}

/// D256: why the app is asked to quit.
enum AppQuitReason: Equatable, Sendable {
    /// ⌘Q, the Quit menu item or the Dock's Quit.
    case user
    /// Log out, restart or shut down.
    case sessionEnding
    /// Sparkle installs an update and relaunches.
    case updateRelaunch
    /// Quit Completely in the panel, or this app was uninstalled.
    case final
    /// Another program asked (a script, an installer, Activity Monitor): it
    /// wants the app gone, as `build_and_run.sh` does before replacing it.
    case otherProgram

    /// The quit Apple event names log out, restart and shut down in its
    /// reason attribute. ⌘Q sends no Apple event; the Dock's Quit and the app
    /// switcher's come from the Dock. A quit from any other sender process is
    /// another program's; with no sender recorded it counts as the user's.
    static func from(quitEvent: NSAppleEventDescriptor?,
                     senderIsDock: (pid_t) -> Bool = AppQuitReason.isDock) -> AppQuitReason {
        guard let quitEvent, quitEvent.eventClass == appleEventCode("aevt"),
              quitEvent.eventID == appleEventCode("quit") else { return .user }
        let key = appleEventCode("why?")
        let reason = quitEvent.attributeDescriptor(forKeyword: key) ?? quitEvent.paramDescriptor(forKeyword: key)
        // keySenderPIDAttr: filled in by the Apple Event Manager on delivery.
        let sender = quitEvent.attributeDescriptor(forKeyword: appleEventCode("spid"))?.int32Value ?? 0
        return classify(reasonCode: reason?.enumCodeValue, senderPID: sender, senderIsDock: senderIsDock)
    }

    /// A quit event's reason and sender process (0 when none was recorded).
    static func classify(reasonCode: OSType?, senderPID: pid_t, senderIsDock: (pid_t) -> Bool) -> AppQuitReason {
        if let reasonCode, sessionEndingCodes.contains(reasonCode) { return .sessionEnding }
        guard senderPID > 0, senderPID != getpid(), !senderIsDock(senderPID) else { return .user }
        return .otherProgram
    }

    static func isDock(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    /// kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
    /// kAEShowShutdownDialog and kAEShutDown (AERegistry.h).
    private static let sessionEndingCodes = Set(["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(appleEventCode))
}

enum AppQuitDecision: Equatable, Sendable {
    case keepMenuBarPanel
    case terminate
}

/// D256: only a user's quit, with the panel installed and the setting on,
/// closes just the main program. Everything else ends the process.
enum AppQuitPolicy {
    static func decision(reason: AppQuitReason, keepsMenuBarPanel: Bool, hasMenuBarPanel: Bool) -> AppQuitDecision {
        reason == .user && keepsMenuBarPanel && hasMenuBarPanel ? .keepMenuBarPanel : .terminate
    }
}

/// D271: an update installed from the menu-bar-only state relaunches into
/// it. The mark names the build that installed it, so only the next launch
/// of a different build, soon after, starts with the panel alone.
enum MenuBarOnlyRelaunch {
    static let key = "app.relaunchIntoMenuBarOnlyAfterUpdate.v1"
    static let validity: TimeInterval = 15 * 60

    static func mark(fromBuild build: String, at date: Date = Date(), _ defaults: UserDefaults = .standard) {
        defaults.set(["build": build, "at": date.timeIntervalSince1970], forKey: key)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// True once: a failed install relaunches (or is reopened as) the same build.
    static func consume(currentBuild: String, now: Date = Date(), _ defaults: UserDefaults = .standard) -> Bool {
        guard let mark = defaults.dictionary(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        guard let build = mark["build"] as? String, let at = mark["at"] as? TimeInterval else { return false }
        let age = now.timeIntervalSince1970 - at
        return build != currentBuild && age >= 0 && age < validity
    }
}

/// D258: a login item's launch carries keyAELaunchedAsLogInItem in the
/// open-application event's property data.
enum AppLaunchKind {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == appleEventCode("aevt"),
              event.eventID == appleEventCode("oapp") else { return false }
        return event.paramDescriptor(forKeyword: appleEventCode("prdt"))?.enumCodeValue == appleEventCode("lgit")
    }
}

/// A four-character Apple event code, as AERegistry.h writes them.
private func appleEventCode(_ text: String) -> OSType {
    text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

/// D256: the reasons that outrank the quit event itself.
@MainActor
final class AppQuitIntent {
    static let shared = AppQuitIntent()

    private(set) var isFinal = false
    private(set) var isSessionEnding = false
    private var powerOffObserver: NSObjectProtocol?

    init() {}

    /// Log out, restart and shut down are announced before the quit event.
    func startObservingSession() {
        guard powerOffObserver == nil else { return }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteSessionEnding() }
        }
    }

    func noteSessionEnding() { isSessionEnding = true }

    /// Set before a termination that must end the process (uninstalling this app).
    func markFinal() { isFinal = true }

    /// Quit Completely: the usual termination work runs and the process exits.
    func requestFinalTermination() {
        markFinal()
        NSApp.terminate(nil)
    }

    func reason(currentEvent: NSAppleEventDescriptor?, isInstallingUpdate: Bool) -> AppQuitReason {
        if isFinal { return .final }
        if isSessionEnding { return .sessionEnding }
        if isInstallingUpdate { return .updateRelaunch }
        return AppQuitReason.from(quitEvent: currentEvent)
    }
}

/// D257: the main program is closed and only the menu-bar panel runs: no
/// Dock icon or main menu, live monitoring and fan control unchanged, and the
/// main window's data released once nothing runs (D259).
@MainActor
final class MenuBarOnlyMode: ObservableObject {
    struct Dependencies {
        var cancelBenchmark: @MainActor () -> Void
        var closeWindows: @MainActor () -> Void
        var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
        var flushMetrics: @MainActor () async -> Void
        /// False while work runs that the data belongs to.
        var releaseMemory: @MainActor () -> Bool
        var waitUntilIdle: @MainActor () async -> Void
        var openMainWindow: @MainActor () -> Void
        var activate: @MainActor () -> Void
        /// D271: a held update does not relaunch the app under an open panel.
        var isPanelShown: @MainActor () -> Bool
    }

    static let shared = MenuBarOnlyMode(dependencies: nil)

#if DEBUG || STORAGE_CLEANER_BETA
    /// D258 on a device without logging out: a launch with this argument
    /// starts as a login item's launch would.
    static var isLoginLaunchRehearsalRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--rehearse-login-launch")
    }
#else
    static let isLoginLaunchRehearsalRequested = false
#endif

    @Published private(set) var isActive = false
    private var dependencies: Dependencies?
    private var suppressesLaunchWindow = false
    private var releaseTask: Task<Void, Never>?
    /// D271: Sparkle's silent install, held for this state.
    private var pendingUpdateInstall: (@MainActor () -> Void)?

    init(dependencies: Dependencies?) {
        self.dependencies = dependencies
    }

    var isConfigured: Bool { dependencies != nil }

    func configure(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// D258: a login launch starts in this state; the main window SwiftUI
    /// opens at launch is built (so it can be opened later) but not shown.
    func beginAtLaunch() {
        isActive = true
        suppressesLaunchWindow = true
    }

    var isLaunchWindowSuppressionPending: Bool { suppressesLaunchWindow }

    /// True once, for the window SwiftUI opens at a login launch; taken when
    /// the suppressor reaches that window, not when a view is merely built.
    func takeLaunchWindowSuppression() -> Bool {
        defer { suppressesLaunchWindow = false }
        return suppressesLaunchWindow
    }

    /// D257: a user's quit while the panel stays.
    func enter() {
        guard !isActive, let dependencies else { return }
        isActive = true
        dependencies.cancelBenchmark()
        dependencies.closeWindows()
        dependencies.setActivationPolicy(.accessory)
        scheduleRelease(dependencies)
    }

    /// Open Main Program, or the app opened again from Finder or Spotlight.
    func leave() {
        guard isActive else { return }
        isActive = false
        // D270: a launch window SwiftUI has not shown yet is shown after all.
        suppressesLaunchWindow = false
        releaseTask?.cancel()
        releaseTask = nil
        // Before the launch work configured the dependencies (a login
        // launch's first moments) the same steps run directly.
        let dependencies = dependencies ?? Dependencies(
            cancelBenchmark: {}, closeWindows: {}, setActivationPolicy: { NSApp.setActivationPolicy($0) },
            flushMetrics: {}, releaseMemory: { true }, waitUntilIdle: {},
            openMainWindow: { MainWindowReopenCoordinator.shared.requestMainWindow() },
            activate: { NSApp.activate(ignoringOtherApps: true) }, isPanelShown: { false })
        dependencies.setActivationPolicy(.regular)
        dependencies.openMainWindow()
        dependencies.activate()
    }

    /// An external event (Finder's uninstall request) opens its own window.
    func leaveWithoutOpeningWindow() {
        guard isActive else { return }
        isActive = false
        releaseTask?.cancel()
        releaseTask = nil
        if let dependencies {
            dependencies.setActivationPolicy(.regular)
            dependencies.activate()
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// D270: the panel can be reached only while its status item shows. When
    /// the item does not show (System Settings does not allow it in the menu
    /// bar, so the system never places it, or no item was installed), the
    /// main program comes back instead of a process nobody can see.
    func statusItemVisibilityChanged(isShowing: Bool) {
        guard isActive, !isShowing else { return }
        leave()
    }

    /// D271: Sparkle installs a silently downloaded update when the process
    /// exits, which a quit no longer does. The install waits for this state,
    /// with nothing running and the panel closed, and relaunches into it.
    func holdUpdateInstall(_ install: @escaping @MainActor () -> Void) {
        pendingUpdateInstall = install
        if isActive, let dependencies { scheduleRelease(dependencies) }
    }

    var holdsUpdateInstall: Bool { pendingUpdateInstall != nil }

    private func scheduleRelease(_ dependencies: Dependencies) {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            await dependencies.flushMetrics()
            var released = false
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                if !released { released = dependencies.releaseMemory() }
                if released {
                    guard let install = self.pendingUpdateInstall else { return }
                    if !dependencies.isPanelShown() {
                        self.pendingUpdateInstall = nil
                        install()
                        return
                    }
                }
                await dependencies.waitUntilIdle()
            }
        }
    }

    /// The main windows and the Settings window; the panel and its alerts stay.
    static func closeMainProgramWindows() {
        for window in NSApp.windows where window.isVisible {
            let identifier = window.identifier?.rawValue ?? ""
            if identifier.hasPrefix("main-") || identifier.localizedCaseInsensitiveContains("settings") {
                window.close()
            }
        }
    }
}

/// D255: the launch work runs once, from applicationDidFinishLaunching,
/// whether or not a main window appears; the main window is a fallback.
@MainActor
final class AppLaunchCoordinator {
    static let shared = AppLaunchCoordinator()

    private var work: (@MainActor (AppDelegate?) -> Void)?
    private var isStarted = false
    private var isStartRequested = false
    private weak var registeredDelegate: AppDelegate?

    init() {}

    /// Set before any window appears, from applicationWillFinishLaunching.
    func register(delegate: AppDelegate) {
        registeredDelegate = delegate
    }

    func prepare(_ work: @escaping @MainActor (AppDelegate?) -> Void) {
        self.work = work
        if isStartRequested { run(delegate: nil) }
    }

    func start(delegate: AppDelegate?) {
        guard work != nil else {
            isStartRequested = true
            return
        }
        run(delegate: delegate)
    }

    private func run(delegate: AppDelegate?) {
        guard !isStarted, let work else { return }
        isStarted = true
        work(delegate ?? registeredDelegate)
    }
}

/// D257: a context menu is built with its view, so the panel overview's copy
/// of the More items ("Open Main Program" or "Open Main Window") is rebuilt
/// here when the main program is quit or opened again while the panel stays
/// open (install24 kept "Open Main Window"). Only the menu is rebuilt; the
/// overview keeps its own subscriptions.
struct MenuBarOnlyAwareContextMenu<MenuItems: View>: ViewModifier {
    @ObservedObject private var menuBarOnly = MenuBarOnlyMode.shared
    let menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        content.contextMenu { menuItems() }
    }
}

/// D258: the main window SwiftUI opens at a login launch is built but never
/// shown, as the latency script's suppressor does (that one is Debug/Beta only).
struct HiddenLaunchWindowSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SuppressorView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if MenuBarOnlyMode.shared.isLaunchWindowSuppressionPending { hide(newWindow) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, MenuBarOnlyMode.shared.takeLaunchWindowSuppression() else { return }
            hide(window)
            DispatchQueue.main.async { [weak window] in
                window?.orderOut(nil)
                window?.close()
            }
        }

        private func hide(_ window: NSWindow?) {
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -60_000, y: -60_000))
        }
    }
}
