import SwiftUI

struct BrowserPrivacyWorkspaceView: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isPresentationFixture
    @Environment(\.featureDemoPrimaryAction) private var demoAction
#endif
    @State private var showingDataTypes = false
    @State private var dataWorking = false
    /// D154 batch 2: the review list was opened from the Protection tiles;
    /// tests of the D67 list keep it as the result.
    @State private var showsList = false
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    @ObservedObject var browserPrivacyStore: BrowserPrivacyStore
    @ObservedObject var malware: MalwareScanStore
    @StateObject private var recentItems = RecentItemsStore()
    let recentItemsCoordinator: HeavyWorkCoordinator?
    let onRecentOperationComplete: () -> Void
    /// D202: the browsing records are Smart Care's scan (or the result it
    /// left); the page keeps its landing for them, its Review excepted.
    let recordsAreSmartCares: Bool
    /// D202: the page's own scan takes the records back from Smart Care.
    let onScan: () -> Void

    // Integration: D186's initializer also takes D188's recent-item inputs.
    init(browserPrivacyStore: BrowserPrivacyStore, malware: MalwareScanStore? = nil,
         recentItemsCoordinator: HeavyWorkCoordinator? = nil, onRecentOperationComplete: @escaping () -> Void = {},
         recordsAreSmartCares: Bool = false, onScan: @escaping () -> Void = {}) {
        self.browserPrivacyStore = browserPrivacyStore
        self.malware = malware ?? MalwareScanStore()
        self.recentItemsCoordinator = recentItemsCoordinator
        self.onRecentOperationComplete = onRecentOperationComplete
        self.recordsAreSmartCares = recordsAreSmartCares
        self.onScan = onScan
    }

    private func startProtectionScan() {
        // D202: not over Smart Care's scan of the records (it would restart it).
        guard !(recordsAreSmartCares && browserPrivacyStore.state == .scanning) else { return }
        onScan()
        browserPrivacyStore.startScan()
        malware.startScan()
    }

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
        .onChange(of: browserPrivacyStore.error) { _, error in
            if error == .cancelled { malware.cancel() }
        }
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
            if browserPrivacyStore.state == .scanning && !recordsAreSmartCares {
                BrowserPrivacyRunningPage(onCancel: browserPrivacyStore.cancel)
                    .overlay(alignment: .bottom) {
                        if malware.isScanning { MalwareScanStatusView(store: malware).padding(16) }
                    }
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
            } else if !usesClassicPages && !showsList {
                CareStudioProtectionResults(privacy: browserPrivacyStore, malware: malware,
                                            onReview: { showsList = true }, onShowDataTypes: showDataTypes,
                                            recentItems: recentItems, recentItemsCoordinator: recentItemsCoordinator,
                                            onRecentOperationComplete: onRecentOperationComplete)
                    .task {
#if DEBUG
                        guard !FeaturePresentationDemo.isEnabled, !isPresentationFixture else { return }
#endif
                        guard recentItemsCoordinator != nil else { return }
                        await recentItems.scan()
                    }
            } else {
                privacyContent
            }
        }
        // A new scan opens on its results again.
        .onChange(of: browserPrivacyStore.state == .scanning) { _, scanning in if scanning { showsList = false } }
    }

    private var heroPage: some View {
        FeatureLightfieldPage(module: .privacy, phase: .landing, title: ReviewFilter.privacy.title,
            status: browserPrivacyStore.state == .idle ? L10n.text("尚未读取记录", "Records not read") : L10n.text("等待重新扫描", "Ready to scan again"),
            safety: L10n.text("只读扫描 · 删除前确认", "Read-only scan · Confirm before deletion"),
            actionTitle: L10n.text("扫描安全防护", "Scan Protection"),
            // D202: off while Smart Care reads the records (as the page's own
            // scanning page used to stand in front of it).
            actionEnabled: !(recordsAreSmartCares && browserPrivacyStore.state == .scanning),
            statusActionTitle: Self.dataTypesTitle,
            statusActionEnabled: browserPrivacyStore.state != .scanning,
            statusAction: showDataTypes, action: {
#if DEBUG
                if let demoAction { demoAction(); return }
#endif
                startProtectionScan()
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
        // D154 batch 3E: from the Protection tiles the records open in the
        // manager panel; the classic layout keeps the D67 page.
        BrowserPrivacyRecordResultsView(store: browserPrivacyStore, onShowDataTypes: showDataTypes,
                                        onShowResults: usesClassicPages ? nil : { showsList = false },
                                        presentsManager: !usesClassicPages)
#if DEBUG
            .layoutProbe(LayoutProbeID.privacy)
#endif
    }

    /// Read in the current language each time (a stored `let` kept the
    /// language of its first use).
    static var dataTypesTitle: String { L10n.text("Cookie 与其他数据", "Cookies and Other Data") }

    private func showDataTypes() {
        guard browserPrivacyStore.state != .scanning else { return }
        showingDataTypes = true
    }

    private var shouldUseHeroPresentation: Bool {
        Self.showsLanding(browserPrivacyStore: browserPrivacyStore, malware: malware,
                          recordsAreSmartCares: recordsAreSmartCares)
    }

    /// The landing page rather than the results; the sidebar's mark (report
    /// §4 item 16) reads the same rule. D202: records that are Smart Care's
    /// keep the landing (a malware result of the page's own goes with them:
    /// the page's own scan reads both).
    static func showsLanding(browserPrivacyStore: BrowserPrivacyStore, malware: MalwareScanStore,
                             recordsAreSmartCares: Bool = false) -> Bool {
        if recordsAreSmartCares { return true }
        if malware.isScanning || malware.outcome != nil { return false }
        return switch browserPrivacyStore.state {
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
