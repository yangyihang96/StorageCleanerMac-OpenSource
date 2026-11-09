import CryptoKit
import Foundation

/// D266: what an AI refers to an item by. The App's own IDs are often paths
/// (`InstalledAppItem`, `StorageItem`) or hold one (`launchd:/Users/…/x.plist`,
/// `com.foo|/Applications/Foo.app`): they would leak the path, and rewriting
/// the home folder to `~` would stop them matching. A token is keyed with a
/// secret of this run, so nothing can be worked out from an item, and only
/// tokens actually handed out lead back to an item: an arbitrary path an AI
/// makes up simply finds nothing.
public final class AgentItemTokens: @unchecked Sendable {
    private let lock = NSLock()
    private let secret: SymmetricKey
    private let maximumPerModule: Int
    private var known: [String: [String: String]] = [:]

    /// The limit bounds memory; only items actually read get a token. Past it
    /// the module starts over, and old tokens read as unknown items.
    public init(maximumPerModule: Int = 50_000) {
        secret = SymmetricKey(size: .bits256)
        self.maximumPerModule = maximumPerModule
    }

    /// The same item in the same module keeps its token for this run of the App.
    public func token(for internalID: String, module: String) -> String {
        let token = tokenWithoutRemembering(for: internalID, module: module)
        lock.withLock {
            if known[module, default: [:]].count >= maximumPerModule, known[module]?[token] == nil { known[module] = [:] }
            known[module, default: [:]][token] = internalID
        }
        return token
    }

    public func tokenWithoutRemembering(for internalID: String, module: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data((module + "\u{0}" + internalID).utf8), using: secret)
        return module + "-" + code.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// The App's own ID, or nil for anything that was not handed out.
    public func internalID(for token: String, module: String) -> String? {
        lock.withLock { known[module]?[token] }
    }

    /// The module's results changed: old tokens read as unknown items.
    public func forget(module: String) {
        _ = lock.withLock { known.removeValue(forKey: module) }
    }
}
