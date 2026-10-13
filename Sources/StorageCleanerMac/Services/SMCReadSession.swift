@preconcurrency import AppKit
import Foundation

/// Only the description of a key is stable across samples. Its bytes are not.
struct SMCKeyInfo: Equatable, Sendable {
    let dataSize: UInt32
    let dataType: String
}

enum SMCDriverRead<Value: Sendable>: Sendable {
    case success(Value)
    case missing
    case unreadable
    case disconnected
}

extension SMCDriverRead: Equatable where Value: Equatable {}

enum SMCReadFailure {
    /// A transport failure cannot prove a key absent. Only the controller's
    /// explicit key-not-found status is eligible for negative caching.
    static func classify<Value: Sendable>(transportSucceeded: Bool, deviceResult: UInt8) -> SMCDriverRead<Value> {
        guard transportSucceeded else { return .disconnected }
        return deviceResult == 0x84 ? .missing : .unreadable
    }
}

/// Implementations are owned by one session and called on its hardware queue.
/// No write selector is exposed, including to injected test drivers.
protocol SMCReadDriver: AnyObject {
    func open() -> Bool
    func close()
    func keyInfo(for key: UInt32) -> SMCDriverRead<SMCKeyInfo>
    func readBytes(for key: UInt32, info: SMCKeyInfo) -> SMCDriverRead<[UInt8]>
}

/// A process-wide read connection for thermal, power and battery consumers.
/// A pass runs on the hardware queue through discovery and live reads. Sleep
/// notifications only update short-lived lifecycle state and enqueue cleanup.
final class SMCReadSession: @unchecked Sendable {
    static let shared = SMCReadSession(
        driver: SMCConnection(),
        platform: .current,
        lifecycleCenter: NSWorkspace.shared.notificationCenter
    )

    private enum CachedInfo {
        case present(SMCKeyInfo)
        case missing
    }

    private static let maximumCachedKeys = 512
    private let lifecycleLock = NSLock()
    private let hardwareQueue = DispatchQueue(label: "com.local.StorageCleanerMac.smc-read-session")
    private let hardwareQueueKey = DispatchSpecificKey<Bool>()
    private let driver: any SMCReadDriver
    let platform: SMCPlatform
    private let lifecycleCenter: NotificationCenter?
    private var observers: [any NSObjectProtocol] = []
    private var isOpen = false
    private var isSleeping = false
    private var lifecycleGeneration: UInt64 = 0
    private var keyInfoByKey: [UInt32: CachedInfo] = [:]

    /// No lifecycle subscription or hardware access unless explicitly supplied.
    init(driver: any SMCReadDriver, platform: SMCPlatform, lifecycleCenter: NotificationCenter? = nil) {
        self.driver = driver
        self.platform = platform
        self.lifecycleCenter = lifecycleCenter
        hardwareQueue.setSpecific(key: hardwareQueueKey, value: true)
        if let lifecycleCenter {
            observers = [
                lifecycleCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                    self?.setSleeping(true)
                },
                lifecycleCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                    self?.setSleeping(false)
                }
            ]
        }
    }

    deinit {
        if let lifecycleCenter { observers.forEach(lifecycleCenter.removeObserver) }
        if DispatchQueue.getSpecific(key: hardwareQueueKey) == true {
            invalidateConnection()
        } else {
            hardwareQueue.sync { invalidateConnection() }
        }
    }

    /// Readers must be used synchronously inside this closure. On transport
    /// loss, the rest of this pass is unreadable; only the next pass reconnects.
    /// Failed opens therefore cost one attempt per pass, not one per probe.
    /// A lifecycle change invalidates the whole result, including values
    /// collected before a later probe crossed sleep or wake.
    func withReadPass<Result>(fallback: @autoclosure () -> Result, _ body: (SMCReadPass) -> Result) -> Result {
        // Reject sleeping requests before they can wait behind an active read.
        guard let generation = readGeneration() else { return fallback() }
        func performReadPass() -> Result {
            guard canRead(generation: generation) else { return fallback() }
            if !isOpen {
                guard driver.open() else { return fallback() }
                isOpen = true
            }
            guard canRead(generation: generation) else { return fallback() }
            let result = body(SMCReadPass(platform: platform, read: { self.lookup($0, generation: generation) }))
            guard canRead(generation: generation) else { return fallback() }
            return result
        }
        return hardwareQueue.sync(execute: performReadPass)
    }

    func readRaw(_ key: String) -> SMCKeyRead {
        withReadPass(fallback: .unreadable) { $0.readRaw(key) }
    }

    /// Metadata inspection never performs a hardware read and also waits for
    /// any previously enqueued lifecycle cleanup to finish.
    var cachedKeyInfoCount: Int {
        hardwareQueue.sync { keyInfoByKey.count }
    }

    /// Never waits for a physical read. Enqueue while holding the short lock so
    /// a subsequent reader cannot overtake this transition's cleanup. Both
    /// sleep and wake invalidate metadata; wake reconnects only on a new pass.
    func setSleeping(_ sleeping: Bool) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        isSleeping = sleeping
        lifecycleGeneration &+= 1
        hardwareQueue.async { [weak self] in self?.invalidateConnection() }
    }

    private func readGeneration() -> UInt64? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isSleeping ? nil : lifecycleGeneration
    }

    private func canRead(generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !isSleeping && lifecycleGeneration == generation
    }

    private func invalidateConnection() {
        if isOpen { driver.close() }
        isOpen = false
        keyInfoByKey.removeAll(keepingCapacity: true)
    }

    private func cache(_ info: CachedInfo, for key: UInt32) {
        if keyInfoByKey.count >= Self.maximumCachedKeys {
            keyInfoByKey.removeAll(keepingCapacity: true)
        }
        keyInfoByKey[key] = info
    }

    private func lookup(_ key: String, generation: UInt64) -> SMCKeyRead {
        guard canRead(generation: generation), isOpen else { return .unreadable }
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == 4 else { return .missing }
        let code = keyBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let info: SMCKeyInfo
        switch keyInfoByKey[code] {
        case .missing?: return .missing
        case let .present(cached)?: info = cached
        case nil:
            guard canRead(generation: generation) else { return .unreadable }
            switch driver.keyInfo(for: code) {
            case let .success(found):
                guard canRead(generation: generation) else { return .unreadable }
                guard (1...32).contains(found.dataSize), found.dataType.utf8.count == 4 else {
                    return .unreadable
                }
                cache(.present(found), for: code)
                info = found
            case .missing:
                cache(.missing, for: code)
                return .missing
            case .unreadable: return .unreadable
            case .disconnected:
                invalidateConnection()
                return .unreadable
            }
        }
        // Do not cache a value (including zero) or a temporary read failure.
        guard canRead(generation: generation) else { return .unreadable }
        switch driver.readBytes(for: code, info: info) {
        case let .success(bytes):
            guard canRead(generation: generation) else { return .unreadable }
            guard bytes.count == Int(info.dataSize) else { return .unreadable }
            return .present(dataType: info.dataType, bytes: bytes)
        case .missing:
            cache(.missing, for: code)
            return .missing
        case .unreadable: return .unreadable
        case .disconnected:
            invalidateConnection()
            return .unreadable
        }
    }
}

/// Borrowed for a single synchronous, serialized pass; no values are retained.
struct SMCReadPass {
    let platform: SMCPlatform
    fileprivate let read: (String) -> SMCKeyRead

    func readRaw(_ key: String) -> SMCKeyRead { read(key) }

    func readDouble(_ key: String) -> Double? {
        guard case let .present(dataType, bytes) = read(key) else { return nil }
        return SMCValueDecoder.decode(key: key, dataType: dataType, bytes: bytes, platform: platform)
    }

    func readFanName(_ key: String) -> String? {
        guard case let .present(dataType, bytes) = read(key) else { return nil }
        return SMCFanSpeedService.decodeFanName(dataType: dataType, bytes: bytes)
    }
}
