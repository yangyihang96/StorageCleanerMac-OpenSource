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
#endif
