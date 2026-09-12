import AppKit
import Foundation

enum MemoryOptimizerError: LocalizedError {
    case processNotFound(String)
    case processIdentityChanged(String)
    case unsafeQuitTarget(String)
    case terminationRejected(String)

    var errorDescription: String? {
        switch self {
        case let .processNotFound(name):
            L10n.text("没有找到正在运行的应用：\(name)", "The running app was not found: \(name)")
        case let .processIdentityChanged(name):
            L10n.text(
                "\(name) 的运行身份已变化，已停止退出以保护其他进程。",
                "The running identity for \(name) changed, so quitting was stopped to protect other processes."
            )
        case let .unsafeQuitTarget(name):
            L10n.text(
                "\(name) 当前不是可安全正常退出的主应用。",
                "\(name) is not currently a regular application that can be quit safely."
            )
        case let .terminationRejected(name):
            L10n.text("\(name) 没有接受正常退出请求。", "\(name) did not accept the normal quit request.")
        }
    }
}

enum MemoryRunningApplicationActivationPolicy: Equatable, Sendable {
    case regular
    case accessory
    case prohibited
}

struct MemoryRunningApplicationIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundlePath: String?
    let executablePath: String?
    let activationPolicy: MemoryRunningApplicationActivationPolicy
    var bundleIdentifier: String? = nil
    var launchDate: Date? = nil
    var userIdentifier: UInt32 = .max
}

/// Compatibility facade for the existing views and store. System reads live in
/// `SystemMemoryProbe`; this type no longer launches `purge` or allocates memory
/// to manufacture a larger "released" number.
enum MemoryOptimizerService {
    static func snapshot() async -> MemorySnapshot {
        await SystemMemoryProbe.shared.snapshot(includeProcesses: true)
    }

    static func statusSnapshot() async -> MemorySnapshot {
        // Skip process enumeration, not the system's read-only pressure query.
        await SystemMemoryProbe.shared.snapshot(includeProcesses: false)
    }

    static func optimize() async -> MemoryOptimizationResult {
        let startedAt = Date()
        let before = await snapshot()
        let after = await snapshot()
        return MemoryOptimizationResult(
            beforeSnapshot: before,
            snapshot: after,
            status: .notNeeded,
            detail: L10n.text(
                "未执行缓存清空。请根据内存压力和交换趋势处理具体应用；系统缓存属于可用内存。",
                "No cache purge was performed. Use memory pressure and swap trends to decide whether to quit specific apps; system cache remains available memory."
            ),
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    @MainActor
    static func quit(_ process: MemoryProcess) throws {
        guard let app = NSRunningApplication(processIdentifier: process.id) else {
            throw MemoryOptimizerError.processNotFound(process.name)
        }
        try validateQuitTarget(
            process,
            against: runningIdentity(for: app),
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        guard app.terminate() else {
            throw MemoryOptimizerError.terminationRejected(process.name)
        }
    }

    static func validateQuitTarget(
        _ process: MemoryProcess,
        against identity: MemoryRunningApplicationIdentity,
        currentProcessIdentifier: Int32
    ) throws {
        guard process.canQuit,
              process.id != currentProcessIdentifier,
              identity.activationPolicy == .regular else {
            throw MemoryOptimizerError.unsafeQuitTarget(process.name)
        }

        let sameBundleIdentifier = process.bundleIdentifier.map {
            $0 == identity.bundleIdentifier
        } ?? true
        let sameLaunchDate = process.launchDate.map { expected in
            identity.launchDate.map { abs($0.timeIntervalSince(expected)) < 0.01 } ?? false
        } ?? true
        let sameUser = process.userIdentifier == .max
            || identity.userIdentifier == .max
            || process.userIdentifier == identity.userIdentifier

        guard identity.processIdentifier == process.id,
              sameBundleIdentifier,
              sameLaunchDate,
              sameUser,
              let expectedBundlePath = normalizedPath(process.bundlePath),
              let currentBundlePath = normalizedPath(identity.bundlePath),
              expectedBundlePath == currentBundlePath,
              let expectedExecutablePath = normalizedPath(process.path),
              let currentExecutablePath = normalizedPath(identity.executablePath),
              expectedExecutablePath == currentExecutablePath else {
            throw MemoryOptimizerError.processIdentityChanged(process.name)
        }
    }

    static func pressureSummary(from output: String) -> (summary: String, freePercentage: Int?) {
        let trimmed = output.trimmed
        guard !trimmed.isEmpty else {
            return (L10n.text("压力数据不可用", "Pressure unavailable"), nil)
        }

        if let percentageLine = trimmed
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.localizedCaseInsensitiveContains("free percentage") }),
           let percentage = percentageLine.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first(where: { !$0.isEmpty }),
           let percentValue = Int(percentage) {
            return (
                L10n.text("压力余量 \(percentValue)%", "Pressure headroom \(percentValue)%"),
                min(100, max(0, percentValue))
            )
        }

        if let firstLine = trimmed.split(separator: "\n").first.map(String.init),
           firstLine.count <= 80 {
            return (firstLine, nil)
        }
        return (L10n.text("压力数据不可用", "Pressure unavailable"), nil)
    }

    @MainActor
    private static func runningIdentity(
        for app: NSRunningApplication
    ) -> MemoryRunningApplicationIdentity {
        let activationPolicy: MemoryRunningApplicationActivationPolicy
        switch app.activationPolicy {
        case .regular: activationPolicy = .regular
        case .accessory: activationPolicy = .accessory
        case .prohibited: activationPolicy = .prohibited
        @unknown default: activationPolicy = .prohibited
        }

        return MemoryRunningApplicationIdentity(
            processIdentifier: app.processIdentifier,
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            activationPolicy: activationPolicy,
            bundleIdentifier: app.bundleIdentifier,
            launchDate: app.launchDate,
            userIdentifier: UInt32(getuid())
        )
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
