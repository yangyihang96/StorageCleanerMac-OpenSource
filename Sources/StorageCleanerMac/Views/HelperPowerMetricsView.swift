import AppKit
import SwiftUI

struct HelperPowerMetricsView: View {
    @ObservedObject var monitor: HelperPowerMetricsMonitor
    var compact = false
    var lightfield = false
    @Environment(\.colorScheme) private var scheme
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    @State private var consumerID = UUID()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selected-category.v1") private var settingsCategory = SettingsCategory.general

    private var permitsLiveDemand: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
#if DEBUG
        if isFixture { return false }
#endif
        return !MiniWindowDemoData.isEnabled
#else
        true
#endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                Text(HelperPowerMetricsPresentation.source)
                    .font(lightfield ? .system(size: 13, weight: .medium) : (compact ? AdvancedPanelTypography.captionStrong : AppTypography.sectionTitle))
                if compact {
                    ForEach(HelperPowerMetricsPresentation.rows(monitor.state, now: context.date)) { row in
                        HStack {
                            Text(row.title)
                            Spacer(minLength: AppDesignTokens.Spacing.small)
                            Text(row.value).monospacedDigit()
                        }
                        .font(AdvancedPanelTypography.caption)
                        .accessibilityElement(children: .combine)
                    }
                } else if lightfield {
                    let rows = HelperPowerMetricsPresentation.rows(monitor.state, now: context.date)
                    ForEach(Array(stride(from: 0, to: rows.count, by: 3)), id: \.self) { start in
                        LightfieldMetricGroup(metrics: rows[start..<min(rows.count, start + 3)].map {
                            LightfieldMetric(id: $0.id, label: $0.title, value: $0.value)
                        }, probeID: "energy.powermetrics.\(start)")
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                              alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                        ForEach(HelperPowerMetricsPresentation.rows(monitor.state, now: context.date)) { row in
                            VStack(alignment: .leading) {
                                Text(row.title).font(AppTypography.caption)
                                Text(row.value).font(AppTypography.body).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Text(HelperPowerMetricsPresentation.detail(monitor.state, now: context.date))
                    .font(compact ? AdvancedPanelTypography.caption : AppTypography.caption)
                    .foregroundStyle(lightfield ? FeatureLightfieldPalette.resolve(scheme).fg2 : AppDesignTokens.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = monitor.lastFailure {
                    Text(HelperPowerMetricsPresentation.detail(.failed(failure), now: context.date))
                        .font(compact ? AdvancedPanelTypography.caption : AppTypography.caption)
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                }
                Button(L10n.text("设置 › 权限 › 系统助手", "Settings › Access › System Helper")) {
                    settingsCategory = .accessAndSetup
                    SystemHelperSettingsNavigation.shared.requestID = UUID()
                    openSettings()
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .font(compact ? AdvancedPanelTypography.caption : AppTypography.caption)
            }
            .foregroundStyle(lightfield ? FeatureLightfieldPalette.resolve(scheme).fg : AppDesignTokens.Palette.primaryText)
        }
        .background {
            PowerMetricsVisibilityProbe { visible in
                monitor.updateConsumer(consumerID, visible: visible && permitsLiveDemand)
            }
            .frame(width: 1, height: 1)
        }
        .onDisappear { monitor.updateConsumer(consumerID, visible: false) }
    }
}

/// SwiftUI onAppear alone does not notice minimization, app hiding or an
/// occluded retained panel. Demand follows the containing window's visibility.
private struct PowerMetricsVisibilityProbe: NSViewRepresentable {
    let onVisibility: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onVisibility = onVisibility
        return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onVisibility = onVisibility
        Task { @MainActor [weak nsView] in nsView?.refreshVisibility() }
    }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.detach() }

    @MainActor
    final class Probe: NSView {
        var onVisibility: (@MainActor (Bool) -> Void)?
        private var asleep = false
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            detachObservers()
            onVisibility?(false)
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibility), name: name,
                    object: name == NSApplication.didHideNotification || name == NSApplication.didUnhideNotification ? nil : window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
                center.addObserver(self, selector: #selector(sleeping), name: name, object: nil)
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                center.addObserver(self, selector: #selector(waking), name: name, object: nil)
            }
            refreshVisibility()
        }
        @objc func refreshVisibility() {
            onVisibility?(!asleep && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
                && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true)
        }
        @objc private func sleeping() { asleep = true; refreshVisibility() }
        @objc private func waking() { asleep = false; refreshVisibility() }
        @objc private func closing() { onVisibility?(false) }
        func detach() { onVisibility?(false); onVisibility = nil; detachObservers() }
        private func detachObservers() {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }
}
