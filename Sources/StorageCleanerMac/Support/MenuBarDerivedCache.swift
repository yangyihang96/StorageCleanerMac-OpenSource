import Foundation

struct MenuBarDerivedKey: Hashable, Sendable {
    let page: String
    let kind: String
    let revision: String
    let configuration: String
    var family: String { page + ":" + kind + ":" + configuration }
}

actor MenuBarDerivedCache {
    static let shared = MenuBarDerivedCache()
    struct Statistics: Sendable { let bytes: Int; let pages: Int; let entries: Int; let builds: Int }
    private struct Entry: Sendable {
        let value: any Sendable
        let cost: Int
        var access: UInt64
    }
    private var entries: [MenuBarDerivedKey: Entry] = [:]
    private var inFlight: [MenuBarDerivedKey: Task<any Sendable, Never>] = [:]
    private var bytes = 0
    private var access: UInt64 = 0
    private var builds = 0
    private var generation = 0
    private let byteLimit: Int
    private let pageLimit: Int

    init(byteLimit: Int = MenuBarPerformancePolicy.derivedCacheByteLimit,
         pageLimit: Int = MenuBarPerformancePolicy.derivedCachePageLimit) {
        self.byteLimit = max(0, byteLimit)
        self.pageLimit = max(0, pageLimit)
    }

    func value<Value: Sendable>(for key: MenuBarDerivedKey, cost: Int,
                                build: @escaping @Sendable () -> Value) async -> Value {
        access &+= 1
        if var entry = entries[key], let value = entry.value as? Value {
            entry.access = access
            entries[key] = entry
            return value
        }
        if let task = inFlight[key], let value = await task.value as? Value { return value }
        let capturedGeneration = generation
        builds += 1
        let task = Task.detached(priority: .userInitiated) { build() as any Sendable }
        inFlight[key] = task
        let value = await task.value as! Value
        inFlight[key] = nil
        guard capturedGeneration == generation, cost >= 0, cost <= byteLimit, pageLimit > 0 else { return value }
        // Retain only the current version of each geometry/range combination.
        for old in entries.keys.filter({ $0.family == key.family }) { remove(old) }
        access &+= 1
        entries[key] = Entry(value: value, cost: cost, access: access)
        bytes += cost
        while Set(entries.keys.map(\.page)).count > pageLimit {
            let pageAccess = Dictionary(grouping: entries, by: { $0.key.page })
                .mapValues { $0.map(\.value.access).max() ?? 0 }
            guard let oldest = pageAccess.min(by: { $0.value < $1.value })?.key else { break }
            for old in entries.keys.filter({ $0.page == oldest }) { remove(old) }
        }
        while bytes > byteLimit || entries.count > 64 {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        return value
    }

    private func remove(_ key: MenuBarDerivedKey) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost }
    }

    func purge() {
        generation &+= 1
        entries.removeAll()
        bytes = 0
    }

    func statistics() -> Statistics {
        Statistics(bytes: bytes, pages: Set(entries.keys.map(\.page)).count, entries: entries.count, builds: builds)
    }
}
