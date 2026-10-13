import SwiftUI

enum FeatureCardPresentation: Equatable, Sendable { case legacy, landing, running }
private struct FeatureCardPresentationKey: EnvironmentKey {
    static let defaultValue: FeatureCardPresentation = .legacy
}
private struct FeatureLayoutAnimationsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var featureCardPresentation: FeatureCardPresentation {
        get { self[FeatureCardPresentationKey.self] }
        set { self[FeatureCardPresentationKey.self] = newValue }
    }
    var featureDisablesLayoutAnimations: Bool {
        get { self[FeatureLayoutAnimationsKey.self] }
        set { self[FeatureLayoutAnimationsKey.self] = newValue }
    }
}

/// Natural document geometry is measured before centering. Every scroller
/// has its own key, including nested memory lists; siblings cannot overwrite it.
private struct FeatureScrollFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum FeatureScrollGeometry {
    static func overflows(contentHeight: CGFloat, availableHeight: CGFloat) -> Bool {
        contentHeight > availableHeight + 0.5
    }
    static func hasContentBelow(content: CGRect, viewport: CGRect) -> Bool {
        content.width > 0 && content.maxY > viewport.maxY + 0.5
    }
    /// The tallest viewport that ends on a clean line of the measured rows:
    /// `resultPartialRowSlice` below a row top (of that row only its empty top
    /// band shows) or at a row bottom (the next block, row or not, is wholly
    /// below). Everything above the cut is whole. Without measured rows, the
    /// list is assumed to start with its 1 pt hairline followed by 52 pt rows.
    static func snappedResultHeight(rowTops: [CGFloat], available: CGFloat, allowsPartialRow: Bool = true) -> CGFloat {
        let slice = FeatureLightfield.resultPartialRowSlice
        let tops = rowTops.isEmpty
            ? stride(from: FeatureLightfield.resultListHairline, through: available, by: FeatureLightfield.rowHeight).map { $0 }
            : rowTops
        let boundaries = tops.filter { $0 > 0.5 }
        let cuts = allowsPartialRow ? boundaries.flatMap { [$0 + slice, $0 + FeatureLightfield.rowHeight] } : boundaries
        guard let cut = cuts.filter({ $0 <= available + 0.5 }).max() else { return max(0, available) }
        return cut
    }
}

/// The hint has its own fixed slot below the clipped scroll viewport. It
/// never overlays text; its slot stays reserved until this document fits.
struct FeatureOptionsScrollView<Content: View>: View {
    @AppSurfaces private var surfaces
    @State private var naturalFrame = CGRect.zero
    @State private var visibleFrame = CGRect.zero
    @State private var rowTops: [CGFloat] = []
    let probePrefix: String
    var balancesContent = true
    var usesLightfield = false
    var showsOverflowHint = true
    var fadesResults = false
    var snapsResultRows = false
    /// Original result rows have a blank top band; compact rows end only at
    /// their measured boundaries, including each expanded child.
    var allowsPartialResultRows = true
    /// Lazy result documents must receive the viewport proposal, rather than
    /// an unbounded ideal height. Other pages retain their measured layout.
    var preservesLazyLayout = false
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let overflowing = FeatureScrollGeometry.overflows(contentHeight: naturalFrame.height,
                                                               availableHeight: proxy.size.height)
            let hintHeight = overflowing && showsOverflowHint && !fadesResults
                ? (usesLightfield ? min(FeaturePageTokens.scrollHintHeight, proxy.size.height / 3) : FeaturePageTokens.scrollHintHeight) : 0
            let fadeHeight = min(CGFloat(24), proxy.size.height)
            // Snapped result lists end on the empty top band of the first
            // incomplete row, measured from the real row tops in the document
            // (toolbars, notices and disclosures above the rows included). The
            // 24 pt fade then covers only row padding and hairlines, so no
            // half-cut text is ever visible (D67).
            let visibleHeight = fadesResults && snapsResultRows && overflowing
                ? FeatureScrollGeometry.snappedResultHeight(rowTops: rowTops, available: proxy.size.height, allowsPartialRow: allowsPartialResultRows)
                : max(0, proxy.size.height - hintHeight)
            let hasMore = overflowing && FeatureScrollGeometry.hasContentBelow(content: naturalFrame, viewport: visibleFrame)
            VStack(spacing: 0) {
                scrollViewport(visibleHeight: visibleHeight, fadeHeight: fadeHeight, availableHeight: proxy.size.height)
                if overflowing && showsOverflowHint && !fadesResults {
                    Group {
                        if hasMore {
                            Group {
                                if usesLightfield { Text(L10n.text("向下滚动查看更多", "Scroll down for more")) }
                                else { Label(L10n.text("向下滚动查看更多", "Scroll down for more"), systemImage: "chevron.down") }
                            }
                                .font(AppDesignTokens.TypeScale.captionEmphasis)
                                .foregroundStyle(usesLightfield ? FeatureLightfieldPalette.resolve(scheme).fg : surfaces.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: hintHeight)
#if DEBUG
                                .layoutProbe("\(probePrefix).scrollHint")
#endif
                        } else { Color.clear.accessibilityHidden(true) }
                    }
                    .frame(height: hintHeight)
                    .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(FeatureScrollFrameKey.self) { frames in
                if let frame = frames[probePrefix + ".natural"], naturalFrame != frame { naturalFrame = frame }
                if let frame = frames[probePrefix + ".visible"], visibleFrame != frame { visibleFrame = frame }
            }
#if DEBUG
            .preference(key: FeatureScrollRenderPreferenceKey.self, value: [probePrefix:
                FeatureScrollRenderSnapshot(naturalHeight: naturalFrame.height,
                    availableHeight: proxy.size.height, visibleHeight: visibleHeight,
                    overflowing: overflowing, showsHint: hasMore && showsOverflowHint && !fadesResults)])
#endif
        }
    }

    private func scrollViewport(visibleHeight: CGFloat, fadeHeight: CGFloat, availableHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            content
                .environment(\.featureLightfieldReportsRowTops, snapsResultRows)
                .fixedSize(horizontal: false, vertical: !preservesLazyLayout)
                .padding(.bottom, fadesResults ? 24 : 0)
                .coordinateSpace(name: FeatureLightfield.resultsDocumentSpace)
                .onPreferenceChange(FeatureLightfieldRowTopKey.self) { tops in
                    // Only rows near the document top decide the snap. Lazy
                    // rows scrolled out of view stop reporting; keep the last
                    // measured tops then, so scrolling never moves the end.
                    let near = tops.filter { $0 <= availableHeight + FeatureLightfield.rowHeight }.sorted()
                    if snapsResultRows, !near.isEmpty, near != rowTops { rowTops = near }
                }
                .background {
                    GeometryReader { document in
                        Color.clear.preference(key: FeatureScrollFrameKey.self,
                            value: [probePrefix + ".natural": document.frame(in: .global)])
                    }
                }
                .frame(maxWidth: .infinity, minHeight: balancesContent ? visibleHeight : nil,
                       alignment: balancesContent ? .leading : .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(height: visibleHeight)
        .clipped()
        .mask { scrollMask(fadeHeight: fadeHeight) }
        .background {
            GeometryReader { viewport in
                Color.clear.preference(key: FeatureScrollFrameKey.self,
                    value: [probePrefix + ".visible": viewport.frame(in: .global)])
            }
        }
#if DEBUG
        .layoutProbe("\(probePrefix).scrollViewport")
        .overlay(alignment: .bottom) {
            if fadesResults {
                Color.clear.frame(height: fadeHeight)
                    .layoutProbe("\(probePrefix).fade")
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
#endif
    }

    @ViewBuilder private func scrollMask(fadeHeight: CGFloat) -> some View {
        if fadesResults {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
        } else { Color.black }
    }
}

/// Sparse lists keep their original row spacing; the common scroll wrapper
/// centers them without changing the document's measured natural height.
struct FeatureOptionList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { FeatureOptionListLayout { content } }
}

private struct FeatureOptionListLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +)
            + CGFloat(max(0, subviews.count - 1)) * FeaturePageTokens.optionRowSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(.init(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: height))
            y += height + FeaturePageTokens.optionRowSpacing
        }
    }
}

struct FeatureRuntimeMetrics: View {
    @AppSurfaces private var surfaces
    let metrics: [RuntimeWorkflowMetric]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<((metrics.count + 2) / 3), id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(metrics.dropFirst(row * 3).prefix(3))) { metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metric.title).font(AppDesignTokens.TypeScale.caption)
                                .foregroundStyle(surfaces.textSecondary)
                            Text(metric.value)
                                .font(.system(size: FeaturePageTokens.metricValueSize, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(surfaces.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .appDataTransition(value: metric.value)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
#if DEBUG
        .layoutProbe("runtime.metrics")
#endif
    }
}

/// Secondary cancellation uses readable neutral text in every canvas, also
/// while stopping. Capability is conveyed by state/help, not text opacity.
struct FeatureCancellationButtonStyle: ButtonStyle {
    @AppSurfaces private var surfaces
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(AppDesignTokens.TypeScale.buttonRegular)
            .foregroundStyle(surfaces.textPrimary)
            .frame(maxWidth: .infinity, minHeight: FeaturePageTokens.cancelHeight)
            .surfaceBackground(.inset, cornerRadius: AppDesignTokens.Corner.button)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The main window owns starts, so navigating away does not restart a task.
/// Only view-layer observations expire ended tasks; no sampler or store writes.
@MainActor
final class FeatureRuntimeClock {
    private var starts: [String: Date] = [:]
    func start(module: ReviewFilter, identity: String?, now: Date = Date()) -> Date {
        let key = "\(module.rawValue):\(identity ?? "current")"
        if let start = starts[key] { return start }
        // Preflight can precede publication of a session ID. Preserve the
        // first visible instant when that same task receives its identity.
        if identity != nil, let start = starts.removeValue(forKey: "\(module.rawValue):current") {
            starts[key] = start
            return start
        }
        starts[key] = now
        return now
    }
    func retain(activeModules: Set<ReviewFilter>) {
        starts = starts.filter { entry in
            activeModules.contains { entry.key.hasPrefix("\($0.rawValue):") }
        }
    }
    func reset() { starts.removeAll() }
}
private struct FeatureRuntimeClockKey: EnvironmentKey {
    static let defaultValue: FeatureRuntimeClock? = nil
}
extension EnvironmentValues {
    var featureRuntimeClock: FeatureRuntimeClock? {
        get { self[FeatureRuntimeClockKey.self] }
        set { self[FeatureRuntimeClockKey.self] = newValue }
    }
}
#if DEBUG
private struct FeatureDemoElapsedKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}
extension EnvironmentValues {
    var featureDemoElapsedSeconds: TimeInterval? {
        get { self[FeatureDemoElapsedKey.self] }
        set { self[FeatureDemoElapsedKey.self] = newValue }
    }
}
#endif
