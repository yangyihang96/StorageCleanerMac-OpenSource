import AppKit
import Foundation

/// CleanMyMac `ApplicationsTerminator`: before removing or updating, the
/// running apps are listed with Quit, Force Quit and Ignore, plus Quit All and
/// Ignore and Continue. This service does the quitting; the sheet only asks.
@MainActor
enum ApplicationTerminator {
    enum Outcome: Equatable, Sendable {
        case quit
        case stillRunning
        case cannotQuit
    }

    /// Running instances of the bundle at `path` (matched by bundle URL, then
    /// by identifier when the URL is unknown).
    static func runningInstances(path: String, bundleIdentifier: String) -> [NSRunningApplication] {
        let target = PathSafety.lexicalPath(path)
        let byIdentifier = bundleIdentifier.isEmpty ? [] : NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let all = byIdentifier.isEmpty ? NSWorkspace.shared.runningApplications : byIdentifier
        return all.filter { app in
            guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            if let url = app.bundleURL { return PathSafety.lexicalPath(url.path) == target }
            return !bundleIdentifier.isEmpty && app.bundleIdentifier == bundleIdentifier
        }
    }

    static func isRunning(path: String, bundleIdentifier: String) -> Bool {
        !runningInstances(path: path, bundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Asks the app to quit (or forces it) and waits up to `timeout`.
    static func quit(path: String, bundleIdentifier: String, force: Bool, timeout: Duration = .seconds(8)) async -> Outcome {
        let instances = runningInstances(path: path, bundleIdentifier: bundleIdentifier)
        guard !instances.isEmpty else { return .quit }
        var accepted = false
        for instance in instances {
            accepted = (force ? instance.forceTerminate() : instance.terminate()) || accepted
        }
        guard accepted else { return .cannotQuit }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if runningInstances(path: path, bundleIdentifier: bundleIdentifier).isEmpty { return .quit }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .stillRunning
    }
}
