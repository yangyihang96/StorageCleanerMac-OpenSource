#if DEBUG
import SwiftUI

enum LayoutProbeID {
    static let contentLayout = "safe-clean.content-layout"
    static let pageViewport = "page.viewport"
    static let workspace = "safe-clean.workspace"
    static let picker = "safe-clean.picker"
    static let privacy = "safe-clean.privacy"
    static let itemListPane = "safe-clean.item-list-pane"
    static let itemDetailPane = "safe-clean.item-detail-pane"
    static let smartScanRoot = "smart-scan.root"
    static let smartScanHeader = "smart-scan.header"
    static let smartScanContent = "smart-scan.content"
    static let smartScanFooter = "smart-scan.footer"
    static let smartScanSidebar = "smart-scan.sidebar"
    static let runtimePanel = "runtime.panel"
    static let runtimeArtwork = "runtime.artwork"
    static let runtimeLocation = "runtime.location"
    static let runtimeViewport = "runtime.viewport"
    static func cleanupRiskSummary(_ risk: CleanupRisk) -> String {
        "cleanup.risk-summary.\(risk.rawValue)"
    }
    static let landingRoot = "concept-landing.root"
    static let landingCanvas = "concept-landing.canvas"
    static let landingContent = "concept-landing.content"
    static let landingHeader = "concept-landing.header"
    static let landingHeaderIcon = "concept-landing.header-icon"
    static let landingHeaderCopy = "concept-landing.header-copy"
    static let landingActionPanel = "concept-landing.action-panel"
    static let landingActionButton = "concept-landing.action-button"
    static let landingActionIcon = "concept-landing.action-icon"
    static let landingActionTitle = "concept-landing.action-title"
    static let landingArtwork = "concept-landing.artwork"
    static let landingFooter = "concept-landing.footer"

    static func landingScopeCard(_ index: Int) -> String {
        "concept-landing.scope-card.\(index)"
    }

    static func landingScopeIcon(_ index: Int) -> String {
        "concept-landing.scope-icon.\(index)"
    }

    static func landingScopeTitle(_ index: Int) -> String {
        "concept-landing.scope-title.\(index)"
    }
}

struct LayoutFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func layoutProbe(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LayoutFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .global)]
                )
            }
        }
    }
}

/// Debug-only readback of inputs used by the actual cleanup card bodies.
/// No model/session is retained and no text is synthesized by the test host.
struct GeekCleanupRenderedField: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case heading, notice, metric, item }
    let id: String
    let kind: Kind
    let label: String
    var value: String? = nil
    var detail: String? = nil
}

enum GeekCleanupProbeID {
    static let heading = "mini-cleanup.heading"
    static let notice = "mini-cleanup.notice"
    static let viewport = "mini-cleanup.viewport"
    static let listViewport = "mini-cleanup.list-viewport"
    static let footer = "mini-cleanup.footer"
    static let hint = "mini-cleanup.scroll-hint"
    static func action(_ index: Int) -> String { "mini-cleanup.action.\(index)" }
    static func metric(_ id: String) -> String { "mini-cleanup.metric." + id }
    static func item(_ id: ScanCandidateID) -> String { "mini-cleanup.item." + id.rawValue.uuidString }
}

struct GeekCleanupRenderedPreferenceKey: PreferenceKey {
    static let defaultValue: [String: GeekCleanupRenderedField] = [:]
    static func reduce(value: inout [String: GeekCleanupRenderedField],
                       nextValue: () -> [String: GeekCleanupRenderedField]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func cleanupRenderedProbe(_ fields: [GeekCleanupRenderedField]) -> some View {
        preference(key: GeekCleanupRenderedPreferenceKey.self,
                   value: Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) }))
    }

    /// Row and viewport frames use the same named, top-left SwiftUI space,
    /// independent of the hosting NSView's flipped/screen coordinates.
    func cleanupRowLayoutProbe(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: LayoutFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(GeekCleanupProbeID.viewport))])
            }
        }
    }

    func cleanupViewportProbe() -> some View {
        cleanupRowLayoutProbe(GeekCleanupProbeID.viewport)
            .coordinateSpace(name: GeekCleanupProbeID.viewport)
    }
}
#endif
