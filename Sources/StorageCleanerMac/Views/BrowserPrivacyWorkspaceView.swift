import SwiftUI

struct BrowserPrivacyWorkspaceView: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isPresentationFixture
    @Environment(\.featureDemoPrimaryAction) private var demoAction
#endif
    @State private var showingDataTypes = false
    @State private var dataWorking = false
    @ObservedObject var browserPrivacyStore: BrowserPrivacyStore

    var body: some View {
        // D91: the data-type switch lives inside the locked D67 skeleton
        // (status-bar action on landing/result, header row in the data page);
        // nothing may be stacked above the lightfield title/content frames.
        Group {
            if showingDataTypes {
                BrowserPrivacyDataView(onWorkingChange: { dataWorking = $0 },
                    onShowHistory: { if !dataWorking { showingDataTypes = false } })
            } else {
                historyWorkspace
            }
        }
        .featureFlowTransition(value: browserPrivacyStore.state == .scanning)
        .onAppear {
#if DEBUG
            guard !FeaturePresentationDemo.isEnabled, !isPresentationFixture else { return }
#endif
            BrowserPrivacyRecoveryMaintenance.purgeIfEnabled()
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.workspace)
#endif
    }

    private var historyWorkspace: some View {
        Group {
            if browserPrivacyStore.state == .scanning {
                BrowserPrivacyRunningPage(onCancel: browserPrivacyStore.cancel)
#if DEBUG
                .layoutProbe(LayoutProbeID.privacy)
#endif
            } else if shouldUseHeroPresentation {
                GeometryReader { proxy in
                    heroPage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
#if DEBUG
                .layoutProbe(LayoutProbeID.privacy)
#endif
            } else {
                privacyContent
            }
        }
    }

    private var heroPage: some View {
        FeatureLightfieldPage(module: .privacy, phase: .landing, title: ReviewFilter.privacy.title,
            status: browserPrivacyStore.state == .idle ? L10n.text("尚未读取记录", "Records not read") : L10n.text("等待重新扫描", "Ready to scan again"),
            safety: L10n.text("只读扫描 · 删除前确认", "Read-only scan · Confirm before deletion"),
            actionTitle: L10n.text("扫描浏览器记录", "Scan Browser Records"),
            statusActionTitle: Self.dataTypesTitle,
            statusActionEnabled: browserPrivacyStore.state != .scanning,
            statusAction: showDataTypes, action: {
#if DEBUG
                if let demoAction { demoAction(); return }
#endif
                browserPrivacyStore.startScan()
            }) {
            FeatureOptionsScrollView(probePrefix: "lightfield.options", usesLightfield: true) {
                VStack(spacing: 0) {
                    ForEach(BrowserPrivacyLightfieldPresentation.datePresets) { preset in
                        LightfieldOptionRow(title: preset == .week ? L10n.text("7 天", "7 days") : preset.title,
                            icon: .privacyTimeline, module: .privacy,
                            selection: Binding(get: {
                                BrowserPrivacyDatePreset.matching(browserPrivacyStore.filters, now: Date()) == preset
                            }, set: { selected in
                                guard selected else { return }
                                var filters = browserPrivacyStore.filters
                                preset.apply(to: &filters, now: Date())
                                browserPrivacyStore.filters = filters
                            }))
                    }
                    LightfieldOptionRow(title: L10n.text("按浏览器与域名整理", "Organize by browser and domain"),
                        icon: .privacyGrouping, module: .privacy)
                    LightfieldOptionRow(title: L10n.text("敏感网站折叠 · 删除前备份", "Conceal sensitive sites · Back up before deletion"),
                        icon: .privacyConfirm, module: .privacy)
                    if browserPrivacyStore.state == .permissionDenied {
                        Button(L10n.text("检查授权", "Check Access")) { PrivacySystemSettingsOpener.openFullDiskAccess() }
                            .buttonStyle(FeatureLightfieldRowButtonStyle())
                    }
#if DEBUG
                    Color.clear.frame(height: 1).layoutProbe("lightfield.optionsEnd")
#endif
                }
            }
        }
    }

    private var privacyContent: some View {
        BrowserPrivacyRecordResultsView(store: browserPrivacyStore, onShowDataTypes: showDataTypes)
#if DEBUG
            .layoutProbe(LayoutProbeID.privacy)
#endif
    }

    static let dataTypesTitle = L10n.text("Cookie 与其他数据", "Cookies and Other Data")

    private func showDataTypes() {
        guard browserPrivacyStore.state != .scanning else { return }
        showingDataTypes = true
    }

    private var shouldUseHeroPresentation: Bool {
        switch browserPrivacyStore.state {
        case .idle, .cancelled, .failed:
            true
        case .scanning:
            !browserPrivacyStore.hasCachedResults
        case .permissionDenied:
            browserPrivacyStore.coverage.isEmpty
        case .completed, .partial:
            false
        }
    }

}
