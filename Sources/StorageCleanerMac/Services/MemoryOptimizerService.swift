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
/// `SystemMemoryProbe`. It never launches `purge`; since D144 `optimize()`
/// runs the bounded push of `MemoryReclaimer` and reports the measured
/// counters, never a manufactured "released" number.
enum MemoryOptimizerService {
    static func snapshot() async -> MemorySnapshot {
        await MenuBarPresentationTrace.measureAsyncSample("process.memory.libproc") {
            await SystemMemoryProbe.shared.snapshot(includeProcesses: true)
        }
    }

    static func statusSnapshot() async -> MemorySnapshot {
        let plan = await MenuBarSamplingContext.shared.plan
        return await MenuBarMemoryStatusSampler.shared.snapshot(
            needsRefresh: plan?.primaryKinds.contains(.memoryUsage) ?? true
        )
    }

    /// D144 "释放内存": the bounded push of `MemoryReclaimer`, then a fresh
    /// snapshot. Cancelling the task stops the push between steps.
    static func optimize() async -> MemoryOptimizationResult {
        let startedAt = Date()
        let before = await snapshot()
        let cancellation = MemoryReclaimCancellation()
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                MemoryReclaimer.run(isCancelled: { cancellation.isCancelled })
            }.value
        } onCancel: {
            cancellation.cancel()
        }
        let after = await snapshot()
        return MemoryOptimizationResult(
            beforeSnapshot: before,
            snapshot: after,
            status: reclaimStatus(outcome),
            detail: reclaimDetail(outcome),
            durationSeconds: Date().timeIntervalSince(startedAt),
            reclaim: outcome
        )
    }

    static func reclaimStatus(_ outcome: MemoryReclaimer.Outcome?) -> MemoryOptimizationStatus {
        guard let outcome else { return .unavailable }
        switch outcome.stopReason {
        // Stopping where other apps' memory would start is the designed end.
        case .finished, .compressorGrowing, .pressureRose: return .completed
        case .allocationFailed, .timedOut, .readingUnavailable: return outcome.pushedBytes > 0 ? .partial : .unavailable
        case .cancelled: return .cancelled
        case .nothingToReclaim, .pressureAlreadyRaised: return .notNeeded
        }
    }

    static func reclaimDetail(_ outcome: MemoryReclaimer.Outcome?) -> String {
        guard let outcome else {
            return L10n.text("读不到内存统计，没有执行释放。", "Memory statistics could not be read; nothing was done.")
        }
        switch outcome.stopReason {
        case .finished:
            return L10n.text("系统已收回可以直接丢弃的文件缓存和可清除内存。macOS 会在需要时再次把空闲内存用作缓存。",
                             "The system handed back file cache and purgeable memory it could drop. macOS will use idle memory as cache again when useful.")
        case .compressorGrowing:
            return L10n.text("压缩内存开始增长，已在影响其他应用之前停止。",
                             "The compressor started to grow, so the push stopped before it reached other apps.")
        case .pressureRose:
            return L10n.text("内存压力离开正常，已立即停止并归还全部内存。",
                             "Memory pressure left normal, so the push stopped at once and returned all memory.")
        case .allocationFailed:
            return L10n.text("无法再分配内存，已停止并归还全部内存。", "No more memory could be allocated; the push stopped and returned all memory.")
        case .timedOut:
            return L10n.text("超过 30 秒，已停止并归还全部内存。", "The push stopped after 30 seconds and returned all memory.")
        case .readingUnavailable:
            return L10n.text("读不到内存统计，已停止并归还全部内存。", "Memory statistics became unreadable; the push stopped and returned all memory.")
        case .cancelled:
            return L10n.text("已取消，占用的内存已全部归还。", "Cancelled; all memory used by the push was returned.")
        case .nothingToReclaim:
            return L10n.text("可以收回的文件缓存不足 256 MB，无需释放。", "Less than 256 MB of file cache could be handed back, so nothing was done.")
        case .pressureAlreadyRaised:
            return L10n.text("内存压力已经升高：系统正在自行回收缓存，再施压只会压缩或换出其他应用的内存。请退出占用多的应用。",
                             "Memory pressure is already raised: the system is reclaiming cache itself, and more pressure would only compress or swap other apps. Quit apps that use a lot of memory instead.")
        }
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

    /// The headroom reading for a free percentage (`kern.memorystatus_level`,
    /// or the line `memory_pressure -Q` prints).
    static func pressureSummary(freePercentage percentValue: Int) -> (summary: String, freePercentage: Int?) {
        (
            L10n.text("压力余量 \(percentValue)%", "Pressure headroom \(percentValue)%"),
            min(100, max(0, percentValue))
        )
    }

    /// Reads the output of `memory_pressure -Q`. Since D38 the app no longer
    /// starts that tool (the status reads `kern.memorystatus_level`); the
    /// parser stays as the reference for tests that compare the kernel value
    /// with what the tool prints (`MemoryHeadroomSysctlTests`,
    /// `SystemMonitorServiceTests`) and keeps its own test
    /// (`SystemUtilitySafetyTests`). No production code calls it.
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
            return pressureSummary(freePercentage: percentValue)
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
