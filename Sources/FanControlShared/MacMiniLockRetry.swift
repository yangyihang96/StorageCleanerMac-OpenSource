import Foundation

/// Bounded retries run on the helper command queue, never the application's UI.
/// 6 attempts, 1.55 seconds total backoff; injected pauses make tests instantaneous.
public enum MacMiniLockRetry {
    public static let delays: [TimeInterval] = [0.05, 0.10, 0.20, 0.40, 0.80]

    public static func acquire(tryAcquire: () -> Bool, pause: (TimeInterval) -> Void) -> Bool {
        if tryAcquire() { return true }
        for delay in delays {
            pause(delay)
            if tryAcquire() { return true }
        }
        return false
    }
}

/// A busy boot lock is deferred work, not an unusable/off archive. The runtime
/// keeps this object resident and retries without overwriting unknown intent.
public final class MacMiniDeferredBootstrap<Value> {
    public private(set) var value: Value?
    private let acquire: () -> Bool
    private let release: () -> Void
    private let load: () -> Value

    public init(acquire: @escaping () -> Bool, release: @escaping () -> Void, load: @escaping () -> Value) {
        self.acquire = acquire
        self.release = release
        self.load = load
    }

    @discardableResult
    public func retry(reloadWhen: (Value) -> Bool = { _ in false }) -> Value? {
        if let value, !reloadWhen(value) { return value }
        value = nil
        guard acquire() else { return nil }
        defer { release() }
        let loaded = load()
        value = loaded
        return loaded
    }

    public var isPending: Bool { value == nil }
}
