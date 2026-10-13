import SwiftUI

/// D62: one set of metrics for every landing action and cancellation control.
/// The feature supplies its existing title, options and callbacks only.
enum FeaturePageTokens {
    static let optionIconSide: CGFloat = 48
    static let optionRowSpacing: CGFloat = 16
    static let optionRowMinimumHeight: CGFloat = 56
    static var optionTitleFont: Font { .system(size: 15, weight: .semibold) }
    static let maximumColumnHeight: CGFloat = 380
    // Three V0-sized option controls plus room for their selection chrome.
    static let commonOptionsHeight: CGFloat = optionRowMinimumHeight * 3 + optionRowSpacing * 2 + 24
    static let compositionTopShare: CGFloat = 0.5
    static let metricValueSize: CGFloat = 28
    static let scrollHintHeight: CGFloat = 24
    static var primaryFont: Font { AppDesignTokens.TypeScale.buttonLarge }
    static let primaryCorner = AppDesignTokens.Corner.largeButton
    static let primaryVerticalPadding: CGFloat = 6
    static let primaryHeight: CGFloat = 52
    static let primarySize: GradientButtonStyle.Size = .large
    static let primaryHorizontalPadding: CGFloat = 20
    static let twoColumnMinimumWidth: CGFloat = 560
    static let cancelHeight: CGFloat = 40
    static let cancelSize: GradientButtonStyle.Size = .medium
}

/// The same placement is used by the two feature phases and the Smart Scan
/// result transition. These are layout distances, never drawing offsets.
struct FeatureCompositionGeometry: Equatable {
    let panelHeight: CGFloat
    let artworkSide: CGFloat
    let compositionHeight: CGFloat
    let topSpace: CGFloat
    let headerTop: CGFloat

    init(metrics: LandingMetrics, areaSize: CGSize) {
        panelHeight = metrics.compositionHeight(available:
            max(0, areaSize.height - metrics.headerHeight - metrics.headerGap))
        artworkSide = min(metrics.artworkMaximumSide, areaSize.height,
            max(0, areaSize.width - metrics.actionWidth - metrics.columnSpacing))
        let columnHeight = metrics.headerHeight + metrics.headerGap + panelHeight
        compositionHeight = max(columnHeight, artworkSide)
        topSpace = max(0, areaSize.height - compositionHeight) * FeaturePageTokens.compositionTopShare
        headerTop = topSpace + max(0, compositionHeight - columnHeight) / 2
    }
}

/// V1 compatibility geometry for the eleven routes awaiting D67 migration.
/// Shared geometry for landing and running states. Only the options scroll;
/// header, action and status stay inside the visible page even at 338 pt.
struct FeaturePageScaffold<Header: View, Panel: View, Artwork: View>: View {
    @Environment(\.pageLayout) private var pageLayout
    let systemImage: String
    let status: ScanStatusPresentation
    let trustText: String
    var isRunning = false
    var isDashboard = false
    @ViewBuilder let header: Header
    let panel: (LandingMetrics) -> Panel
    @ViewBuilder let artwork: Artwork

    init(systemImage: String, status: ScanStatusPresentation, trustText: String, isRunning: Bool = false,
         isDashboard: Bool = false,
         @ViewBuilder header: () -> Header, @ViewBuilder panel: @escaping (LandingMetrics) -> Panel,
         @ViewBuilder artwork: () -> Artwork) {
        self.systemImage = systemImage
        self.status = status
        self.trustText = trustText
        self.isRunning = isRunning
        self.isDashboard = isDashboard
        self.header = header()
        self.panel = panel
        self.artwork = artwork()
    }

    var body: some View {
        GeometryReader { proxy in
            let page = pageLayout ?? PageLayout.resolve(size: proxy.size)
            let metrics = LandingMetrics(page: page, size: proxy.size, systemImage: systemImage)
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                GeometryReader { area in
                    let geometry = FeatureCompositionGeometry(metrics: metrics, areaSize: area.size)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geometry.topSpace)
                            .accessibilityHidden(true).allowsHitTesting(false)
                        HStack(alignment: .center, spacing: metrics.columnSpacing) {
                            VStack(alignment: .leading, spacing: metrics.headerGap) {
                                // The dashboard may widen its data, never its header.
                                // Both phases reserve the same title column without scaling text.
                                header.environment(\.pageLayout, page)
                                    .frame(width: metrics.actionWidth, height: metrics.headerHeight, alignment: .leading)
#if DEBUG
                                    .layoutProbe(LayoutProbeID.landingHeader)
                                    .layoutProbe(isRunning ? LayoutProbeID.smartScanHeader : "landing.headerFrame")
#endif
                                panel(metrics).environment(\.pageLayout, page)
                                    .frame(height: geometry.panelHeight)
#if DEBUG
                                    .layoutProbe(isRunning ? LayoutProbeID.runtimePanel : LayoutProbeID.landingActionPanel)
                                    .layoutProbe(isRunning ? "runtime.card" : LayoutProbeID.landingContent)
                                    .layoutProbe(isRunning ? LayoutProbeID.runtimeViewport : "landing.panelViewport")
#endif
                            }
                            .frame(width: isDashboard ? area.size.width : metrics.actionWidth)
                            if metrics.showsArtwork && !isDashboard {
                                artwork.frame(width: geometry.artworkSide, height: geometry.artworkSide)
#if DEBUG
                                    .layoutProbe(isRunning ? LayoutProbeID.runtimeArtwork : LayoutProbeID.landingArtwork)
#endif
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.compositionHeight,
                               maxHeight: geometry.compositionHeight, alignment: .leading)
#if DEBUG
                        .layoutProbe(isRunning ? "runtime.composition" : "landing.composition")
#endif
                        Spacer(minLength: 0)
                    }
                    .frame(width: area.size.width, height: area.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
                .layoutProbe(isRunning ? "runtime.compositionArea" : "landing.compositionArea")
                .layoutProbe(isRunning ? "runtime.compositionViewport" : "landing.compositionViewport")
                .layoutProbe(isRunning ? LayoutProbeID.smartScanContent : "landing.bodyFrame")
#endif
                StatusFooter(status: status, trustText: trustText, isCompact: metrics.compactFooter, isIntegrated: true)
                    .help(trustText)
                    .lineLimit(metrics.compactFooter ? 1 : 2)
                    .frame(height: metrics.footerHeight)
#if DEBUG
                    .layoutProbe(LayoutProbeID.landingFooter)
                    .layoutProbe(isRunning ? LayoutProbeID.smartScanFooter : "landing.statusFrame")
#endif
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(maxWidth: PageLayout.landingMaxWidth, maxHeight: .infinity, alignment: .top)
#if DEBUG
            .layoutProbe(LayoutProbeID.landingCanvas)
#endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .pageOwnsScrolling()
#if DEBUG
        .layoutProbe(LayoutProbeID.landingRoot)
        .layoutProbe(isRunning ? LayoutProbeID.smartScanRoot : "landing.pageFrame")
        .preference(key: FeatureBackdropPreferenceKey.self, value: ["feature.column": false, "feature.status": false])
        .onPreferenceChange(FeatureScrollRenderPreferenceKey.self) { values in
            Task { @MainActor in FeatureVisualProbeStore.scrollSnapshots = values }
        }
        .onPreferenceChange(FeatureBackdropPreferenceKey.self) { values in
            Task { @MainActor in FeatureVisualProbeStore.backdrops = values }
        }
        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
            Task { @MainActor in FeatureVisualProbeStore.frames = frames }
        }
#endif
    }
}

/// Published measurements stay authoritative. When a feature has no clock,
/// the first visible running presentation supplies a clearly approximate one.
struct FeatureRunningTemplate<Details: View, Actions: View>: View {
#if DEBUG
    @Environment(\.featureDemoElapsedSeconds) private var demoElapsedSeconds
#endif
    @Environment(\.featureRuntimeClock) private var runtimeClock
    @Environment(\.landingHeaderAction) private var headerAction
    @Environment(\.moduleTheme) private var theme
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.smartScanFlowNamespace) private var flowNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var clockStartedAt = Date()
    @State private var isVisible = false

    let module: ReviewFilter
    let title: String
    var subtitle: String? = nil
    var state: RuntimeWorkflowState = .running
    var fraction: Double? = nil
    var metrics: [RuntimeWorkflowMetric] = []
    var currentItem: String? = nil
    var elapsedSeconds: TimeInterval? = nil
    var taskIdentity: String? = nil
    var pageTitle: String? = nil
    var pageSystemImage: String? = nil
    var trustText = L10n.text("只读扫描 · 清理前逐项确认", "Read-only scan · Review before cleanup")
    var canCancel = false
    var cancelTitle = L10n.text("取消扫描", "Cancel Scan")
    var cancelHelp: String? = nil
    var onCancel: (() -> Void)? = nil
    @ViewBuilder let details: Details
    @ViewBuilder let actions: Actions

    var body: some View {
        Group {
        if FeatureLightfield.owns(module) {
            lightfieldPage
        } else {
        FeaturePageScaffold(systemImage: pageSystemImage ?? module.systemImage,
                            status: .scanning(title), trustText: trustText, isRunning: true) {
            AppPageHeader(title: pageTitle ?? module.sidebarTitle,
                          systemImage: pageSystemImage ?? module.systemImage, isHero: true, role: .landing) {
                if let headerAction { headerAction } else { EmptyView() }
            }
        } panel: { metrics in
            progressPanel(metrics: metrics)
                .modifier(SmartScanFlowMatchModifier(namespace: flowNamespace))
        } artwork: {
            if module == .overview {
                OrbitLandingArtwork.smartScan(isActive: state.isActive)
            } else {
                OrbitLandingArtwork.module(
                    systemImage: pageSystemImage ?? module.systemImage,
                    isActive: state.isActive
                )
            }
        }
        }
        }
        .environment(\.landingHeaderAction, nil)
        .onAppear {
            isVisible = true
            clockStartedAt = runtimeClock?.start(module: module, identity: taskIdentity) ?? Date()
        }
        .onDisappear { isVisible = false }
        .onChange(of: taskIdentity) {
            clockStartedAt = runtimeClock?.start(module: module, identity: taskIdentity) ?? Date()
        }
#if DEBUG
        .preference(key: FeatureRuntimeRenderPreferenceKey.self, value: [module.rawValue:
            FeatureRuntimeRenderSnapshot(stageTitle: title,
                cancellationTitle: cancellationText,
                cancellationHasAction: onCancel != nil,
                cancellationIsEnabled: onCancel != nil && canCancel && state != .stopping,
                safetyText: trustText)])
#endif
    }

    private var lightfieldPage: some View {
        Group {
            if isVisible && state.isActive && measuredElapsedSeconds == nil {
                TimelineView(.periodic(from: clockStartedAt, by: 1)) { context in lightfieldPage(at: context.date) }
            } else { lightfieldPage(at: Date()) }
        }
    }

    private func lightfieldPage(at date: Date) -> some View {
        FeatureLightfieldPage(module: module, phase: .running,
            title: pageTitle ?? module.sidebarTitle,
            // The stage is already the progress label; the status line says
            // the state and, when measured, the percentage (“扫描中 · 64%”).
            status: state.title + (RuntimeWorkflowState.measuredFraction(fraction).map { " · \(Int($0 * 100))%" } ?? ""),
            safety: trustText, actionTitle: cancellationText,
            actionEnabled: onCancel != nil && canCancel && state != .stopping,
            artwork: pageSystemImage == GeneratedArt.similarPhotosSystemImage ? .similarPhotos : nil,
            action: { onCancel?() }) {
            FeatureLightfieldProgress(module: module, state: state, title: title,
                subtitle: subtitle, fraction: fraction, currentItem: currentItem,
                metrics: metrics, elapsed: elapsedText(at: date)) {
                details
            } actions: { actions }
        }
        .help(cancelHelp ?? cancellationText)
    }

    private func elapsedText(at date: Date) -> String {
        let exact = measuredElapsedSeconds
        let seconds = exact ?? max(0, date.timeIntervalSince(clockStartedAt))
        let duration = MacBenchmarkPresentation.durationText(seconds)
        return exact == nil
            ? L10n.text("已用时间约 \(duration)", "Elapsed approximately \(duration)")
            : L10n.text("已用时间 \(duration)", "Elapsed \(duration)")
    }

    private func progressPanel(metrics: LandingMetrics) -> some View {
        let short = metrics.page.height == .short
        let inset = metrics.cardInset
        return VStack(alignment: .leading, spacing: short ? 8 : 16) {
            FeatureOptionsScrollView(probePrefix: "runtime", balancesContent: true) {
                VStack(alignment: .leading, spacing: short ? 8 : 16) {
                    HStack(spacing: 12) {
                        MetricRing(fraction: RuntimeWorkflowState.measuredFraction(fraction),
                                   colors: theme.pigment.gradientStops, lineWidth: 4) {
                            if state == .failed || state == .attention || state == .completed {
                                Image(systemName: state.symbol).foregroundStyle(surfaces.textSecondary)
                            }
                        }
                        .frame(width: short ? 32 : 52, height: short ? 32 : 52)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(AppDesignTokens.TypeScale.sectionTitle)
                                .foregroundStyle(surfaces.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(title).transition(.opacity)

                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                        .accessibilityValue(subtitle ?? "")
                        .accessibilityAddTraits(.isHeader)
                        .animation(AppMotion.resolved(.standard, reduceMotion: reduceMotion), value: title)
#if DEBUG
                        .layoutProbe("runtime.stage")
#endif
                    }
                    progressBar
                    HStack(spacing: 8) {
                        Text(currentItem ?? L10n.text("未提供当前项", "Current item unavailable"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textSecondary)
                    .frame(height: 20, alignment: .leading)
                    .help(currentItem ?? L10n.text("该任务未发布当前项", "This task does not publish its current item"))
                    .accessibilityLabel(L10n.text("当前对象", "Current Item"))
                    .accessibilityValue(currentItem ?? L10n.text("未提供", "Unavailable"))
#if DEBUG
                    .layoutProbe(LayoutProbeID.runtimeLocation)
#endif
                    elapsedLabel
                    if !self.metrics.isEmpty {
                        FeatureRuntimeMetrics(metrics: self.metrics)
                    }
                    details
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
                .layoutProbe("runtime.optionsContent")
                .overlay(alignment: .bottom) { Color.clear.frame(height: 1).layoutProbe("runtime.optionsEnd") }
#endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
            .layoutProbe("runtime.optionsViewport")
#endif
            cancellationSlot
#if DEBUG
            .layoutProbe("runtime.cancel")
#endif
        }
        .padding(inset)
        .environment(\.featureCardPresentation, .running)
    }

    private var progressBar: some View {
        let measured = RuntimeWorkflowState.measuredFraction(fraction)
        return HStack(spacing: 12) {
            ProgressView(value: measured ?? 0, total: 1)
                .tint(theme.actionFill)
                .frame(maxWidth: .infinity)
            Text(measured.map { "\(Int($0 * 100))%" } ?? "—")
                .font(AppDesignTokens.TypeScale.secondaryEmphasis).monospacedDigit()
                .foregroundStyle(surfaces.textSecondary).frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("进度", "Progress"))
        .accessibilityValue(measured.map { "\(Int($0 * 100))%" } ?? L10n.text("未提供进度", "Progress unavailable"))
#if DEBUG
        .layoutProbe("runtime.progress")
#endif
    }

    private var measuredElapsedSeconds: TimeInterval? {
#if DEBUG
        let candidate = elapsedSeconds ?? demoElapsedSeconds
#else
        let candidate = elapsedSeconds
#endif
        return candidate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private var elapsedLabel: some View {
        Group {
            if isVisible && state.isActive && measuredElapsedSeconds == nil {
                TimelineView(.periodic(from: clockStartedAt, by: 1)) { context in
                    elapsedLabel(at: context.date)
                }
            } else {
                elapsedLabel(at: Date())
            }
        }
#if DEBUG
        .layoutProbe("runtime.elapsed")
#endif
    }

    private func elapsedLabel(at date: Date) -> some View {
        let exact = measuredElapsedSeconds
        let seconds = exact ?? max(0, date.timeIntervalSince(clockStartedAt))
        let duration = MacBenchmarkPresentation.durationText(seconds)
        let text = exact == nil
            ? L10n.text("已用时间约 \(duration)", "Elapsed approximately \(duration)")
            : L10n.text("已用时间 \(duration)", "Elapsed \(duration)")
        return Text(text)
            .font(AppDesignTokens.TypeScale.caption)
            .foregroundStyle(surfaces.textSecondary)
            .help(exact == nil
                ? L10n.text("从本次运行页首次显示时估算；不是任务的精确总时长", "Estimated since this running page first appeared; not the task's exact total duration")
                : text)
            .accessibilityLabel(L10n.text("已用时间", "Elapsed Time"))
            .accessibilityValue(text)
    }

    private var cancellationText: String {
        onCancel == nil
            ? L10n.text("此任务不可取消", "Cancellation unavailable")
            : cancelTitle
    }

    private var cancellationSlot: some View {
        Group {
            if let onCancel {
                Button(action: onCancel) {
                    Text(cancellationText).frame(maxWidth: .infinity)
                }
                .buttonStyle(FeatureCancellationButtonStyle())
                .disabled(!canCancel || state == .stopping)
            } else {
                Label(cancellationText, systemImage: "lock")
                    .font(AppDesignTokens.TypeScale.buttonRegular)
                    .foregroundStyle(surfaces.textPrimary)
                    .frame(maxWidth: .infinity)
                    .surfaceBackground(.inset, cornerRadius: AppDesignTokens.Corner.button)
            }
        }
        .frame(height: FeaturePageTokens.cancelHeight)
        .help(cancelHelp ?? (onCancel == nil
            ? L10n.text("此任务没有取消接口，将在读取完成后返回", "This task has no cancellation API and returns when reading finishes")
            : cancelTitle))
    }
}

typealias FeatureRuntimePage<Details: View, Actions: View> = FeatureRunningTemplate<Details, Actions>

/// The common option family: static or selectable rows, tiles, segmented
/// selectors (CapsuleSegmentedControl), and labeled form rows.
struct FeatureOptionRow: View {
    @AppSurfaces private var surfaces
    let title: String
    let systemImage: String
    var probeID: String? = nil
    init(title: String, detail: String = "", systemImage: String,
         pigment: ModulePigment? = nil, probeID: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.probeID = probeID
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FeaturePageTokens.optionTitleFont).foregroundStyle(surfaces.textPrimary)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
            .layoutProbe(probeID.map { "smartScope.copy.\($0)" } ?? "option.copy.\(systemImage)")
#endif
        }
        .padding(.vertical, 4)
        .frame(minHeight: FeaturePageTokens.optionRowMinimumHeight)
        .accessibilityElement(children: .combine)
#if DEBUG
        .layoutProbe(probeID.map { "smartScope.\($0)" } ?? "option.row.\(systemImage)")
#endif
    }
}

/// One inset tile surface for scope grids, selectable cards and capability cards.
struct FeatureOptionCard<Content: View>: View {
    @Environment(\.moduleTheme) private var theme
    @AppSurfaces private var surfaces
    @Environment(\.featureCardPresentation) private var presentation
    var isSelected: Bool? = nil
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(padding)
            .background {
                if presentation == .legacy {
                    SurfaceBackground(level: .inset, cornerRadius: AppDesignTokens.Corner.inset)
                } else {
                    RoundedRectangle(cornerRadius: AppDesignTokens.Corner.inset)
                        .fill(surfaces.hover.opacity(0.45))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppDesignTokens.Corner.inset)
                    .strokeBorder(isSelected == true ? theme.actionFill : surfaces.divider, lineWidth: 1)
            }
    }
}

struct FeatureFormRow<Content: View>: View {
    @AppSurfaces private var surfaces
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(surfaces.textSecondary)
            Spacer(minLength: 8)
            content.foregroundStyle(surfaces.textPrimary)
        }
        .font(AppDesignTokens.TypeScale.body)
        .accessibilityElement(children: .combine)
    }
}

/// A namespace per feature host. The same V0 match links the landing button
/// and running card; progress samples themselves never animate the whole page.
private struct FeatureFlowTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesLayoutAnimations
    @Environment(\.featureLightfieldModule) private var lightfieldModule
    @Environment(\.featureRuntimeClock) private var windowClock
    @Namespace private var namespace
    @State private var runtimeClock = FeatureRuntimeClock()
    let value: Value

    func body(content: Content) -> some View {
        content.environment(\.smartScanFlowNamespace, namespace)
            .environment(\.featureRuntimeClock, windowClock ?? runtimeClock)
            .onChange(of: value) { _, nextValue in
                guard windowClock == nil else { return }
                if let active = nextValue as? Bool {
                    if !active { runtimeClock.reset() }
                    return
                }
#if DEBUG
                if let phase = nextValue as? FeaturePresentationDemo.Phase {
                    if phase == .landing { runtimeClock.reset() }
                    return
                }
#endif
                runtimeClock.reset()
            }
            // D77: a phase swap has one state layer. Its rows and controls own
            // their motion; animating the host retains outgoing text subtrees.
            .animation(lightfieldModule != nil
                ? nil
                : (disablesLayoutAnimations ? nil : (reduceMotion ? AppMotion.reducedFade : AppMotion.pageChange)), value: value)
#if DEBUG
            .onPreferenceChange(FeatureLightfieldStateLayersKey.self) { values in
                Task { @MainActor in FeatureLightfieldResultAudit.layers = values }
            }
#endif
    }
}

extension View {
    func featureFlowTransition<Value: Equatable>(value: Value) -> some View {
        modifier(FeatureFlowTransitionModifier(value: value))
    }
}
