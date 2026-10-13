import Darwin
import Foundation

/// Only a complete ps PID inventory can be shared, never a ranked menu
/// list. Only the next memory read may borrow it, for at most one second;
/// incomplete inventories instead require full native memory discovery.
/// Dynamic counters, birth and permissions are always read by each consumer.
/// The lock also serializes static path/name reads across the two workers.
final class ProcessSamplingCache: @unchecked Sendable {
    static let shared = ProcessSamplingCache()

    struct Metadata: Sendable {
        let path: String
        let bundlePath: String?
        let fallbackName: String
    }

    private struct Entry {
        let birth: UInt64
        let metadata: Metadata
        var psPathHint: String?
        var energyPresentation: EnergyImpactService.EnergyProcessPresentation?
    }

    private struct Inventory {
        let pids: [Int32]
        let publishedAt: TimeInterval
        let isComplete: Bool
    }

    private struct Waiter {
        let flight: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let discover: @Sendable () -> [Int32]?
    private let readPath: (@Sendable (Int32) -> String?)?
    private var pathReader = EnergyImpactService.ExecutablePathReader()
    private let readName: @Sendable (String) -> String
    private let uptime: @Sendable () -> TimeInterval
    private let sharingWindow: TimeInterval
    private let entryLimit: Int
    private let onDiscoveryWait: @Sendable () -> Void
    private var inventory: Inventory?
    private var entries: [Int32: Entry] = [:]
    private var energyFlight: UUID?
    private var waiters: [UUID: Waiter] = [:]

    /// Register before awaiting ps, so the concurrently started memory
    /// worker can use the same discovery regardless of ps completion order.
    func beginEnergyDiscovery() -> UUID {
        let token = UUID()
        let previous = lock.withLock {
            energyFlight = token
            let previous = Array(waiters.values)
            waiters.removeAll()
            return previous
        }
        previous.forEach { $0.continuation.resume() }
        return token
    }

    func finishEnergyDiscovery(
        _ token: UUID,
        pids: [Int32]?,
        cancelled: Bool = false,
        isComplete: Bool = true
    ) {
        let ready: [Waiter] = lock.withLock {
            guard energyFlight == token else { return [] }
            energyFlight = nil
            if let pids {
                let fullList = Self.uniquePIDs(pids)
                inventory = Inventory(pids: fullList, publishedAt: uptime(), isComplete: isComplete)
                if isComplete { retainListedPIDs(fullList) }
            } else if !cancelled {
                inventory = nil
            }
            let ready = waiters.filter { $0.value.flight == token }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            return Array(ready.values)
        }
        ready.forEach { $0.continuation.resume() }
    }

    /// The timeout is a discovery coordination budget, not a sampling
    /// cadence. Each caller owns its wait; neither cancellation nor timeout
    /// cancels ps or another memory reader. No lock is held across an await.
    func memoryProcessIDsAwaitingEnergyDiscovery(
        timeout: Duration = .milliseconds(250)
    ) async -> [Int32]? {
        guard !Task.isCancelled else { return nil }
        let flight = lock.withLock { energyFlight }
        if let flight {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.waitForEnergyDiscovery(flight) }
                group.addTask { try? await Task.sleep(for: timeout) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        guard !Task.isCancelled else { return nil }
        return memoryProcessIDs()
    }

    private func waitForEnergyDiscovery(_ flight: UUID) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let complete = lock.withLock {
                    guard !Task.isCancelled, energyFlight == flight else { return true }
                    waiters[id] = Waiter(flight: flight, continuation: continuation)
                    return false
                }
                if complete { continuation.resume() } else { onDiscoveryWait() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume()
        }
    }

    init(
        discover: @escaping @Sendable () -> [Int32]? = SystemMemoryProbe.discoverAllProcessIDs,
        readPath: (@Sendable (Int32) -> String?)? = nil,
        readName: @escaping @Sendable (String) -> String = { path in
            URL(fileURLWithPath: EnergyImpactService.appBundlePath(in: path) ?? path)
                .deletingPathExtension().lastPathComponent
        },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sharingWindow: TimeInterval = 1,
        entryLimit: Int = 16_384,
        onDiscoveryWait: @escaping @Sendable () -> Void = {}
    ) {
        self.discover = discover
        self.readPath = readPath
        self.readName = readName
        self.uptime = uptime
        self.sharingWindow = max(0, sharingWindow)
        self.entryLimit = max(0, entryLimit)
        self.onDiscoveryWait = onDiscoveryWait
    }

    func publishEnergyDiscovery(_ pids: [Int32], isComplete: Bool = true) {
        lock.withLock {
            let fullList = Self.uniquePIDs(pids)
            inventory = Inventory(pids: fullList, publishedAt: uptime(), isComplete: isComplete)
            if isComplete { retainListedPIDs(fullList) }
        }
    }

    func energyDiscoveryFailed() {
        lock.withLock { inventory = nil }
    }

    func memoryProcessIDs() -> [Int32]? {
        lock.withLock {
            let published = inventory
            inventory = nil // one consumer cannot keep an old discovery alive
            if let published {
                let age = uptime() - published.publishedAt
                if published.isComplete, age >= 0, age <= sharingWindow {
                    return published.pids
                }
            }
            guard let discovered = discover() else { return nil }
            let fullList = Self.uniquePIDs(discovered)
            retainListedPIDs(fullList)
            return fullList
        }
    }

    /// A missing/denied birth is not a cache hit. Failed path reads are not
    /// stored, so a later permission recovery retries the actual provider.
    func metadata(pid: Int32, birth: UInt64?, psPathHint: String? = nil) -> Metadata? {
        lock.withLock {
            let validBirth = birth.flatMap { $0 > 0 ? $0 : nil }
            if let validBirth, var entry = entries[pid], entry.birth == validBirth,
               psPathHint == nil || psPathHint == entry.psPathHint
                || (entry.psPathHint == nil && psPathHint == entry.metadata.path) {
                if entry.psPathHint == nil { entry.psPathHint = psPathHint; entries[pid] = entry }
                return entry.metadata
            }
            entries.removeValue(forKey: pid)
            guard pid > 0 else { return nil }
            let resolvedPath: String?
            if let readPath { resolvedPath = readPath(pid) }
            else { resolvedPath = pathReader.path(of: pid) }
            guard let path = resolvedPath, path.hasPrefix("/"), !path.isEmpty else { return nil }
            let metadata = Metadata(path: path, bundlePath: EnergyImpactService.appBundlePath(in: path),
                                    fallbackName: readName(path))
            if let validBirth, entries.count < entryLimit {
                entries[pid] = Entry(birth: validBirth, metadata: metadata, psPathHint: psPathHint)
            }
            return metadata
        }
    }

    /// Only direct application paths are static. Parent attribution and
    /// Launch Services fallbacks are resolved again, since their owner can
    /// change independently of a child process's birth.
    func energyPresentation(
        row: EnergyProcessRow,
        birth: UInt64?,
        resolve: () -> EnergyImpactService.EnergyProcessPresentation
    ) -> EnergyImpactService.EnergyProcessPresentation {
        lock.withLock {
            guard let birth, birth > 0, var entry = entries[row.pid],
                  entry.birth == birth, entry.metadata.path == row.path,
                  entry.metadata.bundlePath != nil else { return resolve() }
            if let presentation = entry.energyPresentation { return presentation }
            let presentation = resolve()
            entry.energyPresentation = presentation
            entries[row.pid] = entry
            return presentation
        }
    }

    func invalidate(pid: Int32) {
        lock.withLock { _ = entries.removeValue(forKey: pid) }
    }

    private func retainListedPIDs(_ pids: [Int32]) {
        let live = Set(pids)
        entries = entries.filter { live.contains($0.key) }
    }

    private static func uniquePIDs(_ pids: [Int32]) -> [Int32] {
        var seen: Set<Int32> = []
        return pids.filter { $0 > 0 && seen.insert($0).inserted }
    }
}
