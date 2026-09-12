import Foundation

enum PrivacySurface: String, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case edge
    case firefox
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .firefox: "Firefox"
        case .other: L10n.text("其他来源", "Other Sources")
        }
    }

    var systemImage: String {
        switch self {
        case .safari: "safari.fill"
        case .chrome: "circle.hexagongrid.fill"
        case .edge: "wave.3.right.circle.fill"
        case .firefox: "flame.fill"
        case .other: "app.dashed"
        }
    }
}

enum PrivacyTraceKind: String, CaseIterable, Identifiable, Sendable {
    case history
    case downloads
    case cookies
    case profile
    case cache
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: L10n.text("浏览历史", "History")
        case .downloads: L10n.text("下载记录", "Downloads")
        case .cookies: "Cookie"
        case .profile: L10n.text("浏览器资料", "Browser Profile")
        case .cache: L10n.text("缓存", "Cache")
        case .other: L10n.text("其他痕迹", "Other Trace")
        }
    }
}

struct PrivacySurfaceSummary: Identifiable, Sendable {
    let surface: PrivacySurface
    let items: [StorageItem]

    var id: String { surface.id }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var traceCount: Int {
        items.filter { PrivacyTraceClassifier.kind(for: $0) != .cache }.count
    }

    var cacheCount: Int {
        items.filter { PrivacyTraceClassifier.kind(for: $0) == .cache }.count
    }

    var cleanableBytes: Int64 {
        items.filter(\.canMoveToTrash).reduce(0) { $0 + $1.sizeBytes }
    }
}

enum PrivacyTraceClassifier {
    static func visibleItems(in result: ScanResult) -> [StorageItem] {
        result.items.filter {
            $0.sourceID == "privacy_traces" || $0.sourceID == "browser_caches"
        }
    }

    static func summaries(for items: [StorageItem]) -> [PrivacySurfaceSummary] {
        let grouped = Dictionary(grouping: items, by: surface(for:))
        return PrivacySurface.allCases.compactMap { surface in
            guard let items = grouped[surface], !items.isEmpty else { return nil }
            return PrivacySurfaceSummary(
                surface: surface,
                items: items.sorted {
                    if $0.tier.sortRank == $1.tier.sortRank {
                        return $0.sizeBytes > $1.sizeBytes
                    }
                    return $0.tier.sortRank < $1.tier.sortRank
                }
            )
        }
    }

    static func surface(for item: StorageItem) -> PrivacySurface {
        let value = "\(item.title) \(item.path) \(item.kind)".lowercased()
        if value.contains("safari") || value.contains("com.apple.safari") {
            return .safari
        }
        if value.contains("chrome") || value.contains("google/chrome") {
            return .chrome
        }
        if value.contains("edge") || value.contains("microsoft edge") {
            return .edge
        }
        if value.contains("firefox") || value.contains("mozilla") {
            return .firefox
        }
        return .other
    }

    static func kind(for item: StorageItem) -> PrivacyTraceKind {
        let value = "\(item.title) \(item.path) \(item.kind)".lowercased()
        if value.contains("cache") || value.contains("缓存") {
            return .cache
        }
        if value.contains("cookie") {
            return .cookies
        }
        if value.contains("history") || value.contains("历史") {
            return .history
        }
        if value.contains("download") || value.contains("下载") {
            return .downloads
        }
        if value.contains("profile") || value.contains("profiles") || value.contains("配置") {
            return .profile
        }
        return .other
    }
}
