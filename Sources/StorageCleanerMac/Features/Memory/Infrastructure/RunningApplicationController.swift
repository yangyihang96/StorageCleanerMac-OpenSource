import AppKit
import Foundation

@MainActor
protocol MemoryApplicationControlling: AnyObject {
    func preflight(_ target: MemoryOptimizationTarget) -> MemoryPreflightStatus
    func requestGracefulQuit(_ target: MemoryOptimizationTarget) -> Bool
    func requestForceQuit(_ target: MemoryOptimizationTarget) -> Bool
}

@MainActor
final class RunningApplicationController: MemoryApplicationControlling {
    func preflight(_ target: MemoryOptimizationTarget) -> MemoryPreflightStatus {
        guard target.identity.userIdentifier == UInt32(getuid()) else {
            return .permissionDenied
        }
        guard target.identity.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .unsupported
        }
        guard let app = NSRunningApplication(
            processIdentifier: target.identity.processIdentifier
        ) else {
            return .targetExited
        }
        guard app.activationPolicy == .regular else { return .unsupported }
        return matches(app, target: target) ? .ready : .identityChanged
    }

    func requestGracefulQuit(_ target: MemoryOptimizationTarget) -> Bool {
        guard preflight(target) == .ready,
              let app = NSRunningApplication(
                processIdentifier: target.identity.processIdentifier
              ) else { return false }
        return app.terminate()
    }

    func requestForceQuit(_ target: MemoryOptimizationTarget) -> Bool {
        guard preflight(target) == .ready,
              let app = NSRunningApplication(
                processIdentifier: target.identity.processIdentifier
              ) else { return false }
        return app.forceTerminate()
    }

    private func matches(
        _ app: NSRunningApplication,
        target: MemoryOptimizationTarget
    ) -> Bool {
        let expected = target.identity
        guard app.processIdentifier == expected.processIdentifier,
              normalized(app.executableURL?.path) == normalized(expected.executablePath),
              normalized(app.bundleURL?.path) == normalized(expected.bundlePath) else {
            return false
        }
        if let bundleIdentifier = expected.bundleIdentifier,
           app.bundleIdentifier != bundleIdentifier {
            return false
        }
        if let launchDate = expected.launchDate {
            guard let currentLaunchDate = app.launchDate,
                  abs(currentLaunchDate.timeIntervalSince(launchDate)) < 0.01 else {
                return false
            }
        }
        return true
    }

    private func normalized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
