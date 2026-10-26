import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekCleanupPage: some View {
        Group {
            if store.cleanupFeatureConfiguration.mode == .legacy {
                legacyGeekCleanupPage
            } else {
                GeekSmartCleanupPage(
                    model: cleanupDetailsModel,
                    source: MiniWindowCleanupSource(store: store),
                    diskTile: geekCleanupDiskTile,
                    diskAvailableText: storageSnapshot.map { IStatNumberFormat.space($0.userAvailableBytes) } ?? "--",
                    showsExtendedDetails: showsExtendedGeekDetails, actions: geekCleanupActions
                )
            }
        }
    }

    private var legacyGeekCleanupPage: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            GeekMetricSummaryGrid(
                tiles: showsExtendedGeekDetails
                    ? geekCleanupTiles
                    : Array(geekCleanupTiles.prefix(3))
            )

            if showsExtendedGeekDetails {
                GeekResponsiveColumns {
                    geekCleanupStatusCard
                } secondary: {
                    geekCleanupActionableItemsCard
                }
            } else {
                geekCleanupStatusCard
            }

            geekCleanupActions
        }
    }

    private var geekCleanupActions: some View {
        GeekCleanupActions(showsExtendedDetails: showsExtendedGeekDetails,
            reviewSafe: { openApp(filter: .green) }, reviewLargeFiles: { openApp(filter: .largeFiles) },
            openMemory: { openApp(filter: .memory) })
    }

    private var geekCleanupStatusCard: some View {
        AdvancedPanelCard(
            title: cleanupSummaryTitle
        ) {
            GeekTelemetryRow(title: L10n.text("可安全清理", "Safe Cleanup"), value: cleanupPageBytesText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("项目数", "Items"), value: cleanupPageCountText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("启动卷可用", "Startup Disk Available"), value: storageSnapshot.map { IStatNumberFormat.space($0.userAvailableBytes) } ?? "--", tint: AppDesignTokens.Palette.information)
        }
    }

    private var geekCleanupActionableItemsCard: some View {
        AdvancedPanelCard(
            title: L10n.text("可操作项目", "Actionable Items")
        ) {
            if actionableCleanupItems.isEmpty {
                AdvancedUnavailableRow(title: staleCleanupSummaryNotice)
            } else {
                ForEach(actionableCleanupItems) { item in
                    AdvancedCleanupItemRow(item: item)
                }
            }
        }
    }
}

/// Only this mounted page observes live inputs and prepared deliveries.
struct GeekSmartCleanupPage<Actions: View>: View {
    @ObservedObject var model: MiniWindowCleanupDetailsModel
    let source: MiniWindowCleanupSource
    let diskTile: AdvancedMetricTileModel
    let diskAvailableText: String
    let showsExtendedDetails: Bool
    let actions: Actions

    // A pre-appear body uses current inputs, without subscribing or preparing.
    var presentation: MiniWindowCleanupPresentation {
        model.isVisible ? model.presentation : model.presentation(beforeStarting: source.current())
    }

    var body: some View {
        let content = GeekSmartCleanupContent(presentation: presentation, diskTile: diskTile,
            diskAvailableText: diskAvailableText, showsExtendedDetails: showsExtendedDetails, actions: actions,
            layoutRevision: model.layoutRevision)
        return GeekCleanupStableViewport(visibilityID: model.visibilityID, revision: model.layoutRevision,
            isReady: model.isInitialLayoutReady, showsList: showsExtendedDetails) {
            content.header
        } list: { maximumHeight in
            content.actionableCard(maximumHeight: maximumHeight)
        } footer: {
            content.footer
        }
        .onAppear { model.start(source) }
        .onDisappear { model.stop() }
    }
}

struct GeekCleanupLayoutReadiness: Equatable, Sendable {
    let visibilityID: UUID?
    let isReady: Bool
    var revision: UInt64? = nil
    var naturalSize: CGSize? = nil
    var visibleSize: CGSize? = nil
    static let unrestricted = Self(visibilityID: nil, isReady: true)

    /// Report natural height even while the screen/old panel clips the page.
    /// Shell padding and an optional sampling row are measured, not guessed.
    func preferredSize(in shellSize: CGSize) -> CGSize {
        guard isReady, let naturalSize, let visibleSize else { return shellSize }
        return CGSize(width: shellSize.width,
                      height: shellSize.height + naturalSize.height - visibleSize.height)
    }
}

struct GeekCleanupLayoutReadinessKey: PreferenceKey {
    static let defaultValue = GeekCleanupLayoutReadiness.unrestricted
    static func reduce(value: inout GeekCleanupLayoutReadiness, nextValue: () -> GeekCleanupLayoutReadiness) {
        let next = nextValue()
        if next.visibilityID != nil { value = next }
    }
}

struct GeekCleanupNaturalMeasurement: Equatable, Sendable {
    let visibilityID: UUID
    let isReady: Bool
    let size: CGSize
    var revision: UInt64 = 0
}

private struct GeekCleanupNaturalSizeKey: PreferenceKey {
    static let defaultValue: GeekCleanupNaturalMeasurement? = nil
    static func reduce(value: inout GeekCleanupNaturalMeasurement?, nextValue: () -> GeekCleanupNaturalMeasurement?) {
        if let next = nextValue() { value = next }
    }
}

struct GeekCleanupLayoutSettlement: Equatable, Sendable {
    let visibilityID: UUID
    let size: CGSize
    let revision: UInt64

    static func accepting(_ measurement: GeekCleanupNaturalMeasurement, for visibilityID: UUID,
                          revision: UInt64 = 0, previous: Self?) -> Self? {
        guard measurement.visibilityID == visibilityID, measurement.isReady,
              measurement.revision == revision,
              !(previous?.visibilityID == visibilityID && (previous?.revision ?? 0) >= revision),
              measurement.size.width.isFinite, measurement.size.height.isFinite,
              measurement.size.width > 0, measurement.size.height > 0 else { return previous }
        return Self(visibilityID: visibilityID, size: measurement.size, revision: revision)
    }
}

private struct GeekCleanupAvailableHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var geekCleanupAvailableHeight: CGFloat {
        get { self[GeekCleanupAvailableHeightKey.self] }
        set { self[GeekCleanupAvailableHeightKey.self] = newValue }
    }
}

enum GeekCleanupRegion: Hashable, Sendable { case header, footer, rows, listViewport, listCard }

private struct GeekCleanupRegionMeasurement: Equatable, Sendable {
    let size: CGSize
    let revision: UInt64
}

private struct GeekCleanupRegionsKey: PreferenceKey {
    static let defaultValue: [GeekCleanupRegion: GeekCleanupRegionMeasurement] = [:]
    static func reduce(value: inout [GeekCleanupRegion: GeekCleanupRegionMeasurement],
                       nextValue: () -> [GeekCleanupRegion: GeekCleanupRegionMeasurement]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// One settlement per opening/result revision. Only the rows scroll; the
/// notice and existing navigation buttons remain outside that viewport.
struct GeekCleanupStableViewport<Header: View, List: View, Footer: View>: View {
    let visibilityID: UUID
    let revision: UInt64
    let isReady: Bool
    let showsList: Bool
    let header: Header
    let list: (CGFloat?) -> List
    let footer: Footer
    @Environment(\.geekCleanupAvailableHeight) private var availableHeight
    @State private var settled: GeekCleanupLayoutSettlement?
    @State private var regions: [GeekCleanupRegion: GeekCleanupRegionMeasurement] = [:]

    init(visibilityID: UUID, revision: UInt64, isReady: Bool, showsList: Bool,
         @ViewBuilder header: () -> Header, @ViewBuilder list: @escaping (CGFloat?) -> List,
         @ViewBuilder footer: () -> Footer) {
        self.visibilityID = visibilityID
        self.revision = revision
        self.isReady = isReady
        self.showsList = showsList
        self.header = header()
        self.list = list
        self.footer = footer()
    }

    var body: some View {
        let current = settled.flatMap { $0.visibilityID == visibilityID ? $0 : nil }
        let height = current.map { min($0.size.height, max(0, availableHeight)) }
            ?? (availableHeight.isFinite ? max(0, availableHeight) : nil)
        let headerHeight = regions[.header]?.size.height ?? 0
        let footerHeight = regions[.footer]?.size.height ?? 0
        let gaps = GeekPanelLayout.sectionSpacing * (showsList ? 2 : 1)
        let cardChrome = max(0, (regions[.listCard]?.size.height ?? 0) - (regions[.listViewport]?.size.height ?? 0))
        let rowsHeight = regions[.rows]?.size.height ?? 0
        // On a short screen, keep at least one row and its overflow hint
        // reachable before spending the remaining height on summary tiles.
        let minimumRows = min(rowsHeight, GeekCleanupRowLayout.minimumHeight)
            + (rowsHeight > GeekCleanupRowLayout.minimumHeight
                ? GeekCleanupRowLayout.scrollHintHeight + GeekCleanupRowLayout.spacing : 0)
        let shownHeader = height.map { min(headerHeight,
            max(0, $0 - footerHeight - gaps - (showsList ? cardChrome + minimumRows : 0))) }
        let cardBudget = height.map { max(0, $0 - (shownHeader ?? headerHeight) - footerHeight - gaps) }
        let rowBudget = cardBudget.map { max(0, $0 - cardChrome) }
        return VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
                .cleanupMeasure(.header, revision: revision)
                .frame(height: regions[.header] == nil ? nil : shownHeader, alignment: .top)
                .clipped()
                .padding(.bottom, GeekPanelLayout.sectionSpacing)
            if showsList {
                list(rowBudget)
                    .fixedSize(horizontal: false, vertical: true)
                    .cleanupMeasure(.listCard, revision: revision)
                    .frame(maxHeight: cardBudget, alignment: .top)
                    .clipped()
                    .padding(.bottom, GeekPanelLayout.sectionSpacing)
            }
            Spacer(minLength: 0)
            footer.fixedSize(horizontal: false, vertical: true)
                .cleanupMeasure(.footer, revision: revision)
                .layoutPriority(1)
        }
        .frame(height: height, alignment: .top)
        .cleanupViewportReadback()
        .backgroundPreferenceValue(GeekCleanupRegionsKey.self) { values in
            if let size = naturalSize(from: values) {
                Color.clear.preference(key: GeekCleanupNaturalSizeKey.self,
                    value: GeekCleanupNaturalMeasurement(visibilityID: visibilityID,
                        isReady: isReady, size: size, revision: revision))
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: GeekCleanupLayoutReadinessKey.self,
                    value: GeekCleanupLayoutReadiness(visibilityID: visibilityID,
                        isReady: isReady && current?.revision == revision,
                        revision: revision, naturalSize: current?.size, visibleSize: proxy.size))
            }
        }
        .onPreferenceChange(GeekCleanupRegionsKey.self) { values in
            Task { @MainActor in if regions != values { regions = values } }
        }
        .onPreferenceChange(GeekCleanupNaturalSizeKey.self) { measurement in
            guard let measurement else { return }
            Task { @MainActor in
                let next = GeekCleanupLayoutSettlement.accepting(measurement, for: visibilityID,
                    revision: revision, previous: settled)
                if next != settled { settled = next }
            }
        }
    }

    private func naturalSize(from values: [GeekCleanupRegion: GeekCleanupRegionMeasurement]) -> CGSize? {
        let required: [GeekCleanupRegion] = showsList ? [.header, .footer, .rows, .listViewport, .listCard] : [.header, .footer]
        guard required.allSatisfy({ values[$0]?.revision == revision }),
              let header = values[.header]?.size, let footer = values[.footer]?.size else { return nil }
        let card = showsList ? max(0, (values[.listCard]?.size.height ?? 0)
            - (values[.listViewport]?.size.height ?? 0)) + (values[.rows]?.size.height ?? 0) : 0
        return CGSize(width: header.width,
            height: header.height + card + footer.height + GeekPanelLayout.sectionSpacing * (showsList ? 2 : 1))
    }
}

/// A single body in Debug/Release. Probe modifiers inline to identity in Release.
struct GeekSmartCleanupContent<Actions: View>: View {
    let presentation: MiniWindowCleanupPresentation
    let diskTile: AdvancedMetricTileModel
    let diskAvailableText: String
    let showsExtendedDetails: Bool
    let actions: Actions
    var layoutRevision: UInt64 = 0

    var tiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(id: "safe-bytes", title: L10n.text("可安全清理", "Safe Cleanup"),
                                    value: presentation.bytesText, detail: presentation.countText,
                                    tint: AppDesignTokens.Palette.success, progress: nil),
            diskTile,
            AdvancedMetricTileModel(id: "actionable", title: L10n.text("当前可操作", "Actionable Now"),
                                    value: presentation.actionableCountText, detail: presentation.actionableDetail,
                                    tint: AppDesignTokens.Palette.warning, progress: nil)
        ]
    }

    var body: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            header
            if showsExtendedDetails { actionableCard }
            footer
        }
    }

    var header: some View {
        let renderedTiles = tiles
        return VStack(spacing: GeekPanelLayout.sectionSpacing) {
            GeekMetricSummaryGrid(tiles: renderedTiles).cleanupMetricsReadback(renderedTiles)
            statusCard
        }
    }

    var statusCard: some View {
        let renderedTitle = presentation.title
        return AdvancedPanelCard(title: renderedTitle) {
            GeekTelemetryRow(title: L10n.text("可安全清理", "Safe Cleanup"), value: presentation.bytesText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("项目数", "Items"), value: presentation.countText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("启动卷可用", "Startup Disk Available"), value: diskAvailableText, tint: AppDesignTokens.Palette.information)
        }
        .cleanupHeadingReadback(renderedTitle)
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: GeekCleanupRowLayout.spacing) {
            ForEach(presentation.details?.items ?? []) { candidate in
                AdvancedSmartCleanupItemRow(candidate: candidate)
            }
        }
        .opacity(presentation.isUpdating ? 0.45 : 1)
    }

    var actionableCard: some View {
        AdvancedPanelCard(title: L10n.text("可操作项目", "Actionable Items")) { rows }
    }

    func actionableCard(maximumHeight: CGFloat?) -> some View {
        AdvancedPanelCard(title: L10n.text("可操作项目", "Actionable Items")) {
            GeekCleanupItemsViewport(maximumHeight: maximumHeight, revision: layoutRevision) { rows }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: GeekPanelLayout.sectionSpacing) {
            notice
            actions
        }
        .cleanupRegionReadback(.footer)
    }

    var notice: some View {
        let renderedNotice = presentation.notice
        return Text(renderedNotice)
            .font(AdvancedPanelTypography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 34, alignment: .topLeading)
            .cleanupNoticeReadback(renderedNotice)
    }
}

struct GeekCleanupItemsViewport<Content: View>: View {
    let maximumHeight: CGFloat?
    let revision: UInt64
    @ViewBuilder let content: Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        let overflows = maximumHeight.map { naturalHeight > $0 + 1 } ?? false
        let hint = overflows ? GeekCleanupRowLayout.scrollHintHeight + GeekCleanupRowLayout.spacing : 0
        let height = maximumHeight.map { min(naturalHeight, max(0, $0 - hint)) } ?? naturalHeight
        let renderedHint = L10n.text("向下滚动查看更多", "Scroll down to see more")
        return VStack(spacing: GeekCleanupRowLayout.spacing) {
            ScrollView(.vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                    .cleanupMeasure(.rows, revision: revision)
            }
            // The persistent hint below makes overflow visible independently
            // of the user's native scroller style or auto-hide preference.
            .scrollIndicators(.hidden)
            .frame(height: height)
            .scrollBottomFade(height: 14, when: overflows)
            .cleanupRegionReadback(.rows)
            if overflows {
                Text(renderedHint)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: GeekCleanupRowLayout.scrollHintHeight)
                    .cleanupHintReadback(renderedHint)
            }
        }
        .cleanupMeasure(.listViewport, revision: revision)
        .onPreferenceChange(GeekCleanupRegionsKey.self) { values in
            guard let measurement = values[.rows], measurement.revision == revision else { return }
            Task { @MainActor in if naturalHeight != measurement.size.height { naturalHeight = measurement.size.height } }
        }
    }
}

enum GeekCleanupRowLayout {
    static let minimumHeight: CGFloat = 30
    static let spacing: CGFloat = 4
    static let scrollHintHeight: CGFloat = 18
}

struct GeekCleanupActions: View {
    let showsExtendedDetails: Bool
    let reviewSafe: () -> Void
    let reviewLargeFiles: () -> Void
    let openMemory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AppButton(title: L10n.text("查看安全清理", "Review Safe Cleanup"),
                controlSize: .small, fillsWidth: true,
                action: reviewSafe).cleanupActionReadback(0)
            AppButton(title: L10n.text("查看大型文件", "Review Large Files"),
                controlSize: .small, fillsWidth: true,
                action: reviewLargeFiles).cleanupActionReadback(1)
            if showsExtendedDetails {
                AppButton(title: L10n.text("打开内存管理", "Open Memory Management"),
                    controlSize: .small, fillsWidth: true,
                    action: openMemory).cleanupActionReadback(2)
            }
        }
    }
}

/// Summary rows retain no selection, reveal or execution controls.
struct AdvancedSmartCleanupItemRow: View {
    let candidate: ScanCandidate
    var body: some View {
        let renderedName = candidate.sourceURL.lastPathComponent
        let renderedSize = CleanupMeasurementPresentation.value(candidate)
        let renderedCategory = candidate.subcategoryTitle
        return HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(renderedName).font(AdvancedPanelTypography.body.weight(.semibold)).lineLimit(1)
                Text(renderedCategory).font(AdvancedPanelTypography.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(renderedSize).font(AdvancedPanelTypography.compactValue).monospacedDigit().fixedSize()
        }
        .frame(minHeight: GeekCleanupRowLayout.minimumHeight)
        .accessibilityElement(children: .combine)
        .cleanupItemReadback(candidate, name: renderedName, value: renderedSize, detail: renderedCategory)
    }
}

private extension View {
    func cleanupMeasure(_ region: GeekCleanupRegion, revision: UInt64) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: GeekCleanupRegionsKey.self,
                    value: [region: GeekCleanupRegionMeasurement(size: proxy.size, revision: revision)])
            }
        }
    }
}

#if DEBUG
private extension View {
    func cleanupMetricsReadback(_ tiles: [AdvancedMetricTileModel]) -> some View {
        cleanupRenderedProbe(tiles.map {
            GeekCleanupRenderedField(id: GeekCleanupProbeID.metric($0.id), kind: .metric,
                label: $0.title, value: $0.value, detail: $0.detail)
        })
    }
    func cleanupHeadingReadback(_ title: String) -> some View {
        cleanupRenderedProbe([.init(id: GeekCleanupProbeID.heading, kind: .heading, label: title)])
    }
    func cleanupNoticeReadback(_ notice: String) -> some View {
        cleanupRenderedProbe([.init(id: GeekCleanupProbeID.notice, kind: .notice, label: notice)])
            .cleanupRowLayoutProbe(GeekCleanupProbeID.notice)
    }
    func cleanupItemReadback(_ item: ScanCandidate, name: String, value: String, detail: String) -> some View {
        cleanupRenderedProbe([.init(id: GeekCleanupProbeID.item(item.id), kind: .item, label: name, value: value, detail: detail)])
            .cleanupRowLayoutProbe(GeekCleanupProbeID.item(item.id))
    }
    func cleanupActionReadback(_ index: Int) -> some View { cleanupRowLayoutProbe(GeekCleanupProbeID.action(index)) }
    func cleanupHintReadback(_ hint: String) -> some View {
        cleanupRenderedProbe([.init(id: GeekCleanupProbeID.hint, kind: .notice, label: hint)])
            .cleanupRowLayoutProbe(GeekCleanupProbeID.hint)
    }
    func cleanupRegionReadback(_ region: GeekCleanupRegion) -> some View {
        cleanupRowLayoutProbe(region == .rows ? GeekCleanupProbeID.listViewport : GeekCleanupProbeID.footer)
    }
    func cleanupViewportReadback() -> some View { cleanupViewportProbe() }
}
#else
// Private, always-inlined identity modifiers: no Preferences, geometry, IDs,
// payload construction or runtime callbacks in Release. Verify binary symbols
// in the main session as well as the conditional source.
private extension View {
    @inline(__always) func cleanupMetricsReadback(_ tiles: [AdvancedMetricTileModel]) -> Self { self }
    @inline(__always) func cleanupHeadingReadback(_ title: String) -> Self { self }
    @inline(__always) func cleanupNoticeReadback(_ notice: String) -> Self { self }
    @inline(__always) func cleanupItemReadback(_ item: ScanCandidate, name: String, value: String, detail: String) -> Self { self }
    @inline(__always) func cleanupActionReadback(_ index: Int) -> Self { self }
    @inline(__always) func cleanupHintReadback(_ hint: String) -> Self { self }
    @inline(__always) func cleanupRegionReadback(_ region: GeekCleanupRegion) -> Self { self }
    @inline(__always) func cleanupViewportReadback() -> Self { self }
}
#endif
