import SwiftUI

/// Report §4 item 16 (CleanMyMac 5.7.2's sidebar marks, `1比1对照-20261023/cmm/11`–`24`
/// and `cmm2/01`): a small glass disc on a module's mark, on the current
/// module and the others alike. A module at work shows how far it is, a white
/// sector growing clockwise from twelve o'clock — a turning arc where the
/// module cannot know its total; Smart Scan with results waiting shows a
/// yellow dot; a module whose page shows its results shows a white dot.
enum SidebarBadge: Equatable, Sendable {
    /// Scanning, or Smart Scan's Run: the fraction done, `nil` when the
    /// module cannot know its total.
    case progress(Double?)
    /// Smart Scan's results page is waiting (CleanMyMac's yellow dot).
    case attention
    /// The module's page shows its results rather than its landing page.
    case results

    var accessibilityText: String {
        switch self {
        case .progress(let fraction?):
            let percent = Int((fraction * 100).rounded())
            return L10n.text("进行中，已完成 \(percent)%", "In progress, \(percent)% done")
        case .progress(nil):
            return L10n.text("进行中", "In progress")
        case .attention:
            return L10n.text("有待处理的结果", "Results waiting")
        case .results:
            return L10n.text("有结果", "Has results")
        }
    }

    /// The mark of one module. Results follow each page's own choice between
    /// its landing page and its results, so the sidebar and the page agree.
    static func badge(for family: CareStudioFamily, _ inputs: SidebarBadgeInputs) -> SidebarBadge? {
        // The part Smart Scan scans now is drawn on Smart Scan only
        // (`cmm/11`–`13`); Protection's malware scan keeps its own.
        let part = inputs.smartCareStage.scanningPart
        switch family {
        case .smartCare:
            switch inputs.smartCareStage {
            case .scanning: return .progress(inputs.smartCareFraction)
            case .running: return .progress(nil)
            case .results: return .attention
            case .idle, .finished:
                return inputs.mainScanFamily == .smartCare ? .progress(inputs.mainScanFraction) : nil
            }
        case .cleanup:
            if inputs.mainScanFamily == .cleanup { return .progress(inputs.mainScanFraction) }
            return inputs.cleanupShowsResults ? .results : nil
        case .protection:
            if inputs.malwareScanning || (inputs.privacyScanning && part != .protection) { return .progress(nil) }
            return inputs.protectionShowsResults ? .results : nil
        case .performance:
            if inputs.startupLoading && part != .performance { return .progress(nil) }
            return inputs.startupScanned ? .results : nil
        case .applications:
            if inputs.appsLoading && part != .applications { return .progress(nil) }
            return inputs.appsScanned ? .results : nil
        case .clutter:
            if inputs.duplicatesScanning && part != .clutter { return .progress(nil) }
            return inputs.duplicatesScanned ? .results : nil
        case .spaceMap:
            if inputs.storageAnalyzing { return .progress(nil) }
            return inputs.storageAnalyzed ? .results : nil
        case .cloudCleanup:
            if inputs.cloudScanning { return .progress(nil) }
            return inputs.cloudScanned ? .results : nil
        case .myTools:
            return inputs.largeFilesScanning ? .progress(inputs.largeFilesFraction) : nil
        case .myActivity:
            return nil
        }
    }
}

/// What the marks read from the stores, so the rules are testable without
/// them. Fractions are 0...1.
struct SidebarBadgeInputs: Equatable {
    var smartCareStage: SmartCareCoordinator.Stage = .idle
    /// How many of Smart Scan's parts ended.
    var smartCareFraction: Double?
    /// The module of the store's own scan (the junk scans) and how far it is.
    var mainScanFamily: CareStudioFamily?
    var mainScanFraction: Double?
    var cleanupShowsResults = false
    var privacyScanning = false
    var malwareScanning = false
    var protectionShowsResults = false
    var startupLoading = false
    var startupScanned = false
    var appsLoading = false
    var appsScanned = false
    var duplicatesScanning = false
    var duplicatesScanned = false
    var storageAnalyzing = false
    var storageAnalyzed = false
    var cloudScanning = false
    var cloudScanned = false
    /// My Tools' file scan (the movable files).
    var largeFilesScanning = false
    var largeFilesFraction: Double?
}

extension SidebarBadgeInputs {
    /// Each page's own conditions: `CleanupWorkspaceView`,
    /// `BrowserPrivacyWorkspaceView.showsLanding`, the Performance,
    /// Applications and Clutter pages, the Space Map and Cloud Cleanup.
    /// D202: a scan or result that is Smart Care's lights Smart Scan only.
    @MainActor
    init(store: ScanStore, smartCare: SmartCareCoordinator, privacy: BrowserPrivacyStore,
         malware: MalwareScanStore, cloud: CloudCleanupModel) {
        if store.isScanning, let route = store.scanPresentationRoute {
            mainScanFamily = CareStudioFamily(route: route)
            mainScanFraction = store.mainScanProgress.flatMap(Self.fraction)
        }
        smartCareStage = smartCare.stage
        if smartCare.stage.scanningPart != nil {
            smartCareFraction = Self.smartCareFraction(cards: SmartCareModule.allCases.map(smartCare.card))
        }
        cleanupShowsResults = store.cleanupSession(for: .green) != nil || store.cleanupSession(for: .devCaches) != nil
            || (store.cleanupScanSession == nil && store.result != nil)
        let smartCaresRecords = store.smartCareHolds(.protection, privacy: privacy)
        privacyScanning = privacy.state == .scanning && !smartCaresRecords
        malwareScanning = malware.isScanning
        protectionShowsResults = !BrowserPrivacyWorkspaceView.showsLanding(browserPrivacyStore: privacy, malware: malware,
                                                                           recordsAreSmartCares: smartCaresRecords)
        let smartCaresStartup = store.smartCareHolds(.performance)
        startupLoading = store.isLoadingStartupItems && !smartCaresStartup
        startupScanned = store.hasScannedStartupItems && !smartCaresStartup
        appsLoading = store.isLoadingInstalledApps
        appsScanned = store.hasScannedInstalledApps
        let duplicates = store.duplicateFilesWorkspace
        let smartCaresDuplicates = store.smartCareHolds(.clutter)
        duplicatesScanning = duplicates.isScanning && !smartCaresDuplicates
        duplicatesScanned = duplicates.hasScanned && !smartCaresDuplicates
        let files = store.largeFilesWorkspace
        storageAnalyzing = files.isAnalyzingStorage
        storageAnalyzed = files.hasStorageAnalysis
        largeFilesScanning = files.isScanning
        largeFilesFraction = files.progress.flatMap(Self.fraction)
        cloudScanning = cloud.phase == .scanning
        cloudScanned = cloud.phase == .finished && cloud.snapshot != nil
    }

    /// The scanning pages' own rule (`SmartScanProgressView`).
    static func fraction(_ progress: DiskScanProgress) -> Double? {
        progress.progressKind == .determinate ? min(1, max(0, progress.fractionCompleted)) : nil
    }

    /// Smart Scan's selected parts that ended (done, skipped, failed or
    /// stopped), as its scanning page's ring counts them, so the two agree.
    static func smartCareFraction(cards: [SmartCareCardState]) -> Double? {
        let selected = cards.filter { $0 != .off }
        guard !selected.isEmpty else { return nil }
        let ended = selected.filter { card in
            switch card {
            case .done, .skipped, .failed, .stopped: true
            case .off, .waiting, .scanning: false
            }
        }.count
        return Double(ended) / Double(selected.count)
    }
}

private extension SmartCareCoordinator.Stage {
    var scanningPart: SmartCareModule? {
        if case .scanning(let part) = self { return part }
        return nil
    }
}

/// The mark: a 16 pt glass disc on the corner of the module's mark
/// (CleanMyMac's is 17 pt on a 50 pt block; ours sits on a 44 pt one). It
/// takes the studio ink, white at night and dark by day.
struct SidebarBadgeMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let badge: SidebarBadge

    static let diameter: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().fill(CareStudioInk.badgeFill)
            content
            Circle().strokeBorder(CareStudioInk.badgeRim, lineWidth: 0.5)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch badge {
        case .progress(let fraction?):
            SidebarBadgeSector(fraction: fraction)
                .fill(LinearGradient(colors: [CareStudioInk.primary, CareStudioInk.primary.opacity(0.84)],
                                     startPoint: .top, endPoint: .bottom))
                .animation(AppMotion.resolved(.data, reduceMotion: reduceMotion), value: fraction)
        case .progress(nil):
            CareStudioSpinningArc(diameter: 10, lineWidth: 1.6)
        case .attention:
            glow(CareStudioInk.badgeAttention, diameter: 8)
        case .results:
            glow(CareStudioInk.primary, diameter: 7)
        }
    }

    /// CleanMyMac's dots are soft-edged lights in the glass.
    private func glow(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.9), radius: 2)
    }
}

/// The done part of the disc, clockwise from twelve o'clock.
struct SidebarBadgeSector: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let fraction = min(1, max(0, fraction))
        var path = Path()
        guard fraction > 0 else { return path }
        guard fraction < 1 else { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        // y grows downward: an increasing angle runs clockwise on screen.
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}
