#if DEBUG
/// Counts actual production view construction only during a native regression.
/// No identifiers or user history enter this diagnostic.
@MainActor enum BrowserPrivacyRenderProbe {
    static var isEnabled = false
    static var domains = 0
    static var pages = 0
    static func reset() { domains = 0; pages = 0 }
    static func domainBuilt() { if isEnabled { domains += 1 } }
    static func pageBuilt() { if isEnabled { pages += 1 } }
}
#endif
