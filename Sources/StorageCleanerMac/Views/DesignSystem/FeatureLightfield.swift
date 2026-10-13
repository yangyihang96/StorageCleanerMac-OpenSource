import SwiftUI

/// D67 owns landing/running; D77 adds the compact result layout. Other batches
/// retain their page geometry. FeaturePageScaffold remains the V1 adapter.
enum FeatureLightfieldPhase: String, CaseIterable, Sendable { case landing, running, result }

enum FeatureLightfield {
    static let pilots: [ReviewFilter] = [.green, .healthHub, .uninstall]
    static let performancePages: [ReviewFilter] = [.startup, .memory, .energy]
    static func owns(_ module: ReviewFilter) -> Bool {
        pilots.contains(module) || performancePages.contains(module) || [.privacy, .updater, .largeFiles, .migration, .duplicates, .performance].contains(module)
    }
    static let referenceCanvas = CGSize(width: 1070, height: 735)
    static let sidebarWidth: CGFloat = 210
    static let titlebarHeight: CGFloat = 28
    /// Top hairline of a result list document.
    static let resultListHairline: CGFloat = 1
    /// Visible top slice of the first incomplete result row. It is shorter than
    /// the 16 pt gap above a 20 pt check box / 15 pt text in a 52 pt row.
    static let resultPartialRowSlice: CGFloat = 15
    /// Coordinate space of a result list document (row tops for snapping).
    static let resultsDocumentSpace = "lightfield.results.document"
    /// Indent of item rows under their group row (check box 20 + gap 16).
    static let childRowIndent: CGFloat = 36
    /// Width over which the halo fades in from the canvas's left edge.
    static let haloEdgeFade: CGFloat = 96
    /// Row-end disclosure column of result/status rows (same 20 pt as the check box).
    static let disclosureColumn: CGFloat = 20
    static let titleSize: CGFloat = 34
    static let contentWidth: CGFloat = 520
    static let primaryHeight: CGFloat = 52
    static let primaryCorner: CGFloat = 12
    static let statusHeight: CGFloat = 64
    static let optionHeight: CGFloat = 56
    static let rowHeight: CGFloat = 52
    static let checkSide: CGFloat = 20
    static let summaryHeight: CGFloat = 76
    static let summaryGap: CGFloat = 20
    static let listActionGap: CGFloat = 24
    /// D77: results use the full canvas between a compact header and footer.
    static let resultHeaderHeight: CGFloat = 72
    static let resultFooterHeight: CGFloat = 48
    static let resultActionHeight: CGFloat = 32
    static let resultActionHitHeight: CGFloat = 44
    static let resultArtworkSide: CGFloat = 40
    static let compactProcessRowHeight: CGFloat = 48
    static func usesResultSpace(_ module: ReviewFilter) -> Bool {
        [.green, .healthHub, .privacy, .performance, .startup, .memory, .energy, .uninstall].contains(module)
    }
    static let starCount = 90
    // The outer strength is the actual opacity at the centre, not a second
    // multiplier on already translucent gradient stops.
    static let haloCenterOpacity = 1.0
    static let haloMiddleOpacity = 0.40
}

/// All timing, curves and displacements have a single owner. A nil animation
/// means an immediate change, including artwork loading and number counting.
enum FeatureLightfieldMotion {
    static let press = 0.120
    static let pressScale: CGFloat = 0.985
    static let layerFade = 0.240
    static let layerMove = 0.260
    static let layerDistance: CGFloat = 10
    static let completion = 0.560
    static let row = 0.300
    static let rowInterval = 0.040
    static let rowDelay = 0.380
    static let maximumEntranceIndex = 12
    static let rowDistance: CGFloat = 8
    static let number = 0.640
    static let check = 0.160
    static let title = 0.180
    static let artworkFade = 0.260
    static let artworkScale = 0.320
    static let artworkSwapScale: CGFloat = 0.94
    static let color = 0.300
    static let halo = 1.800
    static let haloOpacity = 0.25
    static let haloScale: CGFloat = 1.06
    static let float = 2.400
    static let floatDistance: CGFloat = 6
    static let curve: [Double] = [0.2, 0.8, 0.2, 1]
    static let checkCurve: [Double] = [0.3, 1.6, 0.5, 1]
    static func duration(_ value: Double, reduceMotion: Bool) -> Double { reduceMotion ? 0 : value }
    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(curve[0], curve[1], curve[2], curve[3], duration: duration)
    }
    static func rowAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        animation(row, reduceMotion: reduceMotion)?.delay(rowDelay + Double(min(max(0, index), maximumEntranceIndex)) * rowInterval)
    }
    static func checkAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(checkCurve[0], checkCurve[1], checkCurve[2], checkCurve[3], duration: check)
    }
}

struct FeatureLightfieldPalette: Equatable, Sendable {
    let canvas: [UInt32]
    let sidebar: UInt32
    let sidebarLine: Double
    let foreground: [UInt32]
    let hair: UInt32
    let hover: UInt32
    let star: UInt32
    let starOpacity: Double
    let glow: Double
    let normal: UInt32
    let warning: UInt32
    let failure: UInt32
    static let night = Self(canvas: [0x141B44, 0x0B1230, 0x070B1D], sidebar: 0x0A0F24,
        sidebarLine: 0.06, foreground: [0xF2F5FF, 0xA8B2CC, 0x6F7A96], hair: 0xBAC8FF,
        hover: 0xFFFFFF, star: 0xD2DCFF, starOpacity: 0.55, glow: 0.55,
        normal: 0x3CCF86, warning: 0xFFB340, failure: 0xFF5D6C)
    static let day = Self(canvas: [0xE2EAF6, 0xEEF3FB, 0xF6F8FC], sidebar: 0xE8EEF8,
        sidebarLine: 0.08, foreground: [0x121A33, 0x4F5B78, 0x7E889F], hair: 0x162850,
        hover: 0x162850, star: 0x4664B4, starOpacity: 0.18, glow: 0.32,
        normal: 0x1D9B5C, warning: 0xC77700, failure: 0xD23A4A)
    static func resolve(_ scheme: ColorScheme) -> Self { scheme == .dark ? .night : .day }
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    var warningColor: Color { Self.color(warning) }
    var fg: Color { Self.color(foreground[0]) }
    var fg2: Color { Self.color(foreground[1]) }
    var fg3: Color { Self.color(foreground[2]) }
    var hairColor: Color { Self.color(hair).opacity(0.12) }
    var hoverColor: Color { Self.color(hover).opacity(0.04) }
    static func accents(_ module: ReviewFilter) -> [UInt32]? {
        switch module {
        case .overview: [0x4F8BFF, 0x2A55D6]
        case .green: [0xFF7A2F, 0xC4441A]
        case .devCaches: [0xFFB340, 0xC46A0C]
        case .healthHub: [0x34C77B, 0x1E9E5A]
        case .privacy: [0x2FBF71, 0x168A55]
        case .memory: [0x8B6CFF, 0x5B3FD9]
        case .uninstall: [0xA07BFF, 0x5B3FD9]
        case .duplicates: [0x2CC9D6, 0x0E7C8C]
        // Approved light-field mockups (approved-20261009 shared.js) for the
        // B3–B7 modules; shared components draw them before the pages migrate.
        case .startup, .energy, .performance: [0xFF5FA2, 0xAD1653]
        case .updater: [0xA285FF, 0x5137C7]
        case .largeFiles, .migration: [0x2CC9D6, 0x0E7C8C]
        default: nil
        }
    }
    static func accent(_ module: ReviewFilter, secondary: Bool = false) -> Color {
        if let values = accents(module) { return color(values[secondary ? 1 : 0]) }
        return module.moduleTheme.accent
    }
}

/// Reads placement decisions after the shell has supplied its actual geometry.
/// Used by options/section links to appear exactly once, including short canvases.
struct FeatureLightfieldPlacementReader<Content: View>: View {
    @Environment(\.featureLightfieldHasAccessory) private var hasAccessory
    @Environment(\.featureLightfieldHasSubtitleAccessory) private var hasSubtitleAccessory
    @ViewBuilder let content: (Bool, Bool) -> Content
    var body: some View { content(hasAccessory, hasSubtitleAccessory) }
}

/// Coordinates are local to the actual detail canvas, never the whole window.
/// D77 results opt into a full-height list; other pages keep the D67 geometry.
private struct FeatureLightfieldSubtitleAccessoryKey: EnvironmentKey { static let defaultValue = false }
private struct FeatureLightfieldAccessoryKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var featureLightfieldHasSubtitleAccessory: Bool {
        get { self[FeatureLightfieldSubtitleAccessoryKey.self] }
        set { self[FeatureLightfieldSubtitleAccessoryKey.self] = newValue }
    }
    var featureLightfieldHasAccessory: Bool {
        get { self[FeatureLightfieldAccessoryKey.self] }
        set { self[FeatureLightfieldAccessoryKey.self] = newValue }
    }
}

extension FeatureLightfieldPalette {
    static func fileType(_ type: LightfieldFileCategory) -> Color {
        let value: UInt32 = switch type {
        case .application: 0x55B9BD
        case .system: 0x8194AC
        case .developer: 0x8F7DE1
        case .media: 0x718CE4
        case .archive: 0xCF9960
        case .document: 0x6BB5D2
        case .other: 0xA098B9
        }
        return color(value)
    }
}

struct FeatureLightfieldGeometry: Equatable {
    let title: CGRect
    let content: CGRect
    let primary: CGRect
    let status: CGRect
    let artwork: CGRect
    let halo: CGRect
    var resultSummary: CGRect? = nil
    /// The visual action remains 32 pt; its native button owns at least 44 pt.
    var primaryHitTarget: CGRect {
        primary.insetBy(dx: 0, dy: -max(0, FeatureLightfield.resultActionHitHeight - primary.height) / 2)
    }
    var accessory: CGRect? {
        guard artwork.width >= 240, content.width >= 520, status.minY - artwork.maxY >= 140 else { return nil }
        return CGRect(x: artwork.minX + 40, y: artwork.maxY + 18, width: artwork.width - 40, height: status.minY - artwork.maxY - 34)
    }
    init(size: CGSize, phase: FeatureLightfieldPhase, compactResult: Bool = false) {
        let width = max(1, size.width), height = max(1, size.height)
        if phase == .result && compactResult {
            let inset: CGFloat = width < 600 ? 16 : 24
            let available = max(1, width - inset * 2)
            let titleWidth = min(280, max(120, available * 0.28))
            title = CGRect(x: inset + 56, y: 18, width: titleWidth, height: 40)
            let summaryX = title.maxX + 20
            resultSummary = CGRect(x: summaryX, y: 12, width: max(1, width - inset - summaryX), height: 48)
            status = CGRect(x: inset, y: max(72, height - FeatureLightfield.resultFooterHeight),
                width: available, height: FeatureLightfield.resultFooterHeight)
            let actionWidth = min(200, max(132, available * 0.22))
            primary = CGRect(x: status.maxX - actionWidth, y: status.minY + 8,
                width: actionWidth, height: FeatureLightfield.resultActionHeight)
            content = CGRect(x: inset, y: FeatureLightfield.resultHeaderHeight, width: available,
                height: max(1, status.minY - 8 - FeatureLightfield.resultHeaderHeight))
            artwork = CGRect(x: inset, y: 16, width: FeatureLightfield.resultArtworkSide, height: FeatureLightfield.resultArtworkSide)
            halo = CGRect(x: inset - 160, y: -140, width: 320, height: 320)
            return
        }
        let narrow = width < 760, short = height < 500
        let left: CGFloat = narrow ? min(48, max(24, (width - 520) / 2)) : (width < 1000 ? 48 : 96)
        let columnWidth = narrow ? min(520, max(1, width - left * 2))
            : min(520, max(360, width - left - 100 - 240))
        let titleY: CGFloat = max(48, 92 + (height - 735) / 2)
        let buttonY = height - 140
        // The 160 pt header illustration must finish above narrow content.
        // Short windows scroll this smaller content viewport internally.
        let contentY = short ? titleY + 56
            : narrow ? max(titleY + 84, max(8, titleY - 44) + 176) : titleY + 84
        let titleWidth = narrow ? max(1, width - left - (short ? 104 : 184)) : columnWidth
        title = CGRect(x: left, y: titleY, width: titleWidth, height: 41)
        content = CGRect(x: left, y: contentY,
            width: phase == .result ? max(1, width - left * 2) : columnWidth,
            height: max(1, buttonY - FeatureLightfield.listActionGap - contentY))
        primary = CGRect(x: left, y: buttonY, width: columnWidth, height: FeatureLightfield.primaryHeight)
        let statusInset = min(52, left)
        status = CGRect(x: statusInset, y: height - 64, width: width - statusInset * 2, height: 64)
        if phase == .result {
            artwork = CGRect(x: left, y: contentY, width: 76, height: 76)
            halo = CGRect(x: left - 216, y: contentY - 116, width: 420, height: 420)
        } else if narrow || short {
            let side: CGFloat = narrow && short ? 80 : 160
            artwork = CGRect(x: width - side - 24, y: short ? max(8, titleY - 24) : max(8, titleY - 44), width: side, height: side)
            halo = CGRect(x: artwork.midX - 320, y: artwork.midY - 320, width: 640, height: 640)
        } else {
            // D67's exact reference bounds overlap by 6 pt (616 vs 610).
            // Preserve that reference; other widths have disjoint columns.
            let referenceAllowance: CGFloat = width == 1070 ? 6 : 0
            let available = max(0, width - left - columnWidth - 100 + referenceAllowance)
            let side = min(420, max(240, available))
            artwork = CGRect(x: width - 100 - side, y: 150 + max(0, (height - 735) / 2), width: side, height: side)
            halo = CGRect(x: artwork.midX - 320, y: artwork.midY - 320, width: 640, height: 640)
        }
    }
}

/// Shared by the three production routes. Its only job is presentation; no
/// store, provider, file operation or task progress mutation is retained here.
struct FeatureLightfieldPage<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @Environment(\.smartScanFlowNamespace) private var flowNamespace
    @Environment(\.featureLightfieldBackdropProvided) private var backdropProvided
    @Environment(\.featureOperationHistoryAction) private var openOperationHistory
    let module: ReviewFilter
    let phase: FeatureLightfieldPhase
    let title: String
    let status: String
    let safety: String
    let actionTitle: String
    var actionAccessibilityLabel: String? = nil
    var actionEnabled = true
    /// Content galleries and later summaries may own their 76 pt illustration.
    var showsArtwork = true
    var artwork: GeneratedArt? = nil
    var statusActionTitle = ""
    var statusActionEnabled = true
    var statusAction: (() -> Void)? = nil
    let action: () -> Void
    var subtitle = ""
    var artworkAccessory: AnyView? = nil
    var subtitleAccessory: AnyView? = nil
    @ViewBuilder let content: Content
    private var instant: Bool { reduceMotion || disablesAnimations }
    private var compactResult: Bool { phase == .result && FeatureLightfield.usesResultSpace(module) }
    var body: some View {
        GeometryReader { proxy in
            let geometry = FeatureLightfieldGeometry(size: proxy.size, phase: phase, compactResult: compactResult)
            let hasSubtitleAccessory = !compactResult && subtitleAccessory != nil && geometry.content.width >= 740 && proxy.size.height >= 500
            let palette = FeatureLightfieldPalette.resolve(colorScheme)
            ZStack(alignment: .topLeading) {
                if !backdropProvided {
                    FeatureLightfieldBackdrop(module: module, phase: phase, geometry: geometry)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: compactResult ? 20 : 34, weight: .bold)).tracking(0.34)
                    .foregroundStyle(palette.fg).lineLimit(1).truncationMode(.tail).help(title)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                    if compactResult && !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.fg2)
                            .lineLimit(1).truncationMode(.tail).help(subtitle)
                    }
                }
                    .lightfieldFrame(geometry.title, probe: "lightfield.title")
                content
                    // Count the state subtree itself, including any outgoing
                    // identity a parent transition might otherwise retain.
                    .preference(key: FeatureLightfieldStateLayersKey.self, value: [phase.rawValue: 1])
                    .environment(\.featureLightfieldCompactResults, compactResult)
                    .environment(\.featureLightfieldHasSubtitleAccessory, hasSubtitleAccessory)
                    .environment(\.featureLightfieldHasAccessory, artworkAccessory != nil && phase != .result && geometry.accessory != nil)
                    .id(phase)
                    // D77: replace the state subtree immediately. An outgoing
                    // scan layer must never share the result list's coordinates.
                    .transition(.identity)
                    .lightfieldFrame(geometry.content, probe: "lightfield.content")
                    .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.completion, reduceMotion: instant), value: geometry.content.width)
                if !compactResult && !subtitle.isEmpty && proxy.size.height >= 500 {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.fg2)
                        .lineLimit(1).truncationMode(.tail).help(subtitle)
                        .lightfieldFrame(CGRect(x: geometry.title.minX, y: geometry.content.minY - 30,
                            width: hasSubtitleAccessory ? 240 : geometry.content.width, height: 20), probe: "lightfield.subtitle")
                }
                if hasSubtitleAccessory, let subtitleAccessory {
                    subtitleAccessory.lightfieldFrame(CGRect(x: geometry.content.minX + 264, y: geometry.content.minY - 30,
                        width: geometry.content.width - 264, height: 20), probe: "lightfield.subtitleAccessory")
                }
                if let artworkAccessory, phase != .result, let frame = geometry.accessory {
                    artworkAccessory.lightfieldFrame(frame, probe: "lightfield.artworkAccessory")
                }
                if compactResult || (showsArtwork && (phase != .result || geometry.content.height >= 110)) {
                FeatureLightfieldArtwork(art: artwork ?? GeneratedArt.module(for: module), variant: compactResult ? .header : .landing)
                    .modifier(FeatureLightfieldFloat(phase: phase))
                    .id(module)
                    .transition(.identity)
                    .lightfieldFrame(geometry.artwork, probe: "lightfield.artwork")
                    .modifier(FeatureLightfieldArtworkMatch(namespace: flowNamespace))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                Button(actionTitle, action: action)
                    .buttonStyle(FeatureLightfieldButtonStyle(module: module, isCancel: phase == .running, compact: compactResult))
                    .disabled(!actionEnabled)
                    .accessibilityLabel(actionAccessibilityLabel ?? actionTitle)
                    .accessibilityHint(safety)
                    .lightfieldFrame(geometry.primaryHitTarget, probe: "lightfield.primary.hitTarget")
                // D67/prototype `.status .r`: the 1 pt divider sits 20 pt before
                // the right-aligned safety line, not in the middle of the row.
                HStack(spacing: compactResult ? 12 : 20) {
                    // The window toolbar is hidden on D67 pages, so its
                    // “操作记录” entry lives here as a text button (D64: no icon).
                    if let openOperationHistory {
                        Button(L10n.text("操作记录", "Operation History"), action: openOperationHistory)
                            .buttonStyle(FeatureLightfieldRowButtonStyle(minimumHitHeight: compactResult ? 44 : nil))
                            .foregroundStyle(palette.fg)
                            .fixedSize()
                            .help(L10n.text("查看清理、卸载及迁移回执与恢复", "View cleanup, uninstall and migration receipts and recovery"))
#if DEBUG
                            .layoutProbe("lightfield.status.history")
#endif
                        Rectangle().fill(palette.hairColor).frame(width: 1, height: 22).accessibilityHidden(true)
                    }
                    HStack(spacing: 14) {
                        Text(status).lineLimit(1).truncationMode(.middle).help(status)
                            .lightfieldComponentProbe("lightfield.status.text")
                        if let statusAction {
                            Button(statusActionTitle, action: statusAction)
                                .disabled(!statusActionEnabled)
                                .buttonStyle(FeatureLightfieldRowButtonStyle(minimumHitHeight: compactResult ? 44 : nil))
                                .foregroundStyle(FeatureLightfieldPalette.accent(module))
                                .fixedSize()
                                .lightfieldComponentProbe("lightfield.status.action")
                        }
                    }.frame(minWidth: compactResult ? 0 : 120, maxWidth: .infinity, alignment: .leading)
                    if !compactResult || geometry.status.width >= 740 {
                    Rectangle().fill(palette.hairColor).frame(width: 1, height: 22).accessibilityHidden(true)
#if DEBUG
                        .layoutProbe("lightfield.status.divider")
#endif
                    Text(safety)
#if DEBUG
                        .layoutProbe("lightfield.status.safety")
#endif
                        .lineLimit(1).truncationMode(.tail).help(safety)
                        .accessibilityLabel(safety)
                        .frame(maxWidth: compactResult ? geometry.status.width * 0.30 : nil, alignment: .trailing)
                    }
                }
                .frame(height: compactResult ? FeatureLightfield.resultFooterHeight : nil)
                .padding(.trailing, compactResult ? geometry.primary.width + 16 : 0)
                .font(.system(size: 13)).foregroundStyle(palette.fg2)
                .overlay(alignment: .top) { FeatureLightfieldHairline() }
                .lightfieldFrame(geometry.status, probe: "lightfield.status")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .overlayPreferenceValue(FeatureLightfieldResultSummaryKey.self) { summary in
                if compactResult, let frame = geometry.resultSummary {
                    FeatureLightfieldCompactSummary(summary: summary, fallback: status, module: module)
                        .lightfieldFrame(frame, probe: "lightfield.result.summary")
                }
            }
            .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.color, reduceMotion: instant), value: colorScheme)
#if DEBUG
            .lightfieldRenderedProbe(["title": title, "status": status, "safety": safety, "action": actionTitle])
#endif
        }
        .pageOwnsScrolling()
        .preference(key: FeatureLightfieldPhasePreferenceKey.self, value: phase)
#if DEBUG
        .layoutProbe("lightfield.canvas")
#endif
        .transition(.identity)
#if DEBUG
        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
            Task { @MainActor in FeatureVisualProbeStore.frames = frames }
        }
        .onPreferenceChange(FeatureScrollRenderPreferenceKey.self) { values in
            Task { @MainActor in FeatureVisualProbeStore.scrollSnapshots = values }
        }
        .onPreferenceChange(FeatureLightfieldStateLayersKey.self) { values in
            Task { @MainActor in FeatureLightfieldResultAudit.layers = values }
        }
        .task(id: module.rawValue + ":" + phase.rawValue) { FeatureLightfieldResultAudit.begin(module: module, phase: phase) }
#endif
        .transaction {
            // Only the active phase owns layout and text. Row/check/artwork
            // animations remain locally owned by their existing components.
            $0.animation = nil
            if instant { $0.disablesAnimations = true }
        }
    }
}

private struct FeatureLightfieldFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @Environment(\.scenePhase) private var scenePhase
    let phase: FeatureLightfieldPhase
    func body(content: Content) -> some View {
        let active = phase == .running && !reduceMotion && !disablesAnimations && scenePhase == .active
        TimelineView(.animation(paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            content.offset(y: active ? -FeatureLightfieldMotion.floatDistance *
                CGFloat((1 - cos(time * 2 * .pi / (FeatureLightfieldMotion.float * 2))) / 2) : 0)
        }
    }
}

private struct FeatureLightfieldArtworkMatch: ViewModifier {
    let namespace: Namespace.ID?
    var id = "lightfield.artwork"
    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace) }
        else { content }
    }
}

struct FeatureLightfieldArtwork: View {
    @Environment(\.generatedArtLibrary) private var library
    @Environment(\.generatedArtWindowVisible) private var artWindowVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @State private var loadedImage: CGImage?
    @State private var loadedName: String?
    let art: GeneratedArt?
    let variant: GeneratedArt.Variant
    var body: some View {
        let name = art?.resourceName(variant)
        let picture = loadedName == name ? loadedImage : name.flatMap { library.cachedImage(named: $0) }
        Group {
            if let picture { Image(decorative: picture, scale: 2).resizable().interpolation(.high).scaledToFit() }
            else { Color.clear } // Damaged resources never mix in another illustration style.
        }
        .task(id: GeneratedArtLoadRequest(name: name, visible: artWindowVisible)) {
            guard artWindowVisible else { return }
            guard let name, let picture = await library.image(named: name), !Task.isCancelled else { return }
            withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.artworkFade,
                reduceMotion: reduceMotion || disablesAnimations)) {
                loadedImage = picture
                loadedName = name
            }
        }
        .accessibilityHidden(true)
    }
}

struct FeatureLightfieldBackdrop: View {
    @Environment(\.smartScanFlowNamespace) private var flowNamespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @Environment(\.scenePhase) private var scenePhase
    let module: ReviewFilter
    let phase: FeatureLightfieldPhase
    let geometry: FeatureLightfieldGeometry
    var canvasTopInset: CGFloat = 0
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        let active = phase == .running && !reduceMotion && !disablesAnimations && scenePhase == .active
        TimelineView(.animation(paused: !active)) { context in
            let time = active ? context.date.timeIntervalSinceReferenceDate : 0
            let breath = active ? (1 - cos(time * 2 * .pi / (FeatureLightfieldMotion.halo * 2))) / 2 : 0
            ZStack(alignment: .topLeading) {
                GeometryReader { proxy in
                    let radius = max(proxy.size.width * 1.2, proxy.size.height * 0.9)
                    RadialGradient(stops: [.init(color: FeatureLightfieldPalette.color(palette.canvas[0]), location: 0),
                        .init(color: FeatureLightfieldPalette.color(palette.canvas[1]), location: 0.55),
                        .init(color: FeatureLightfieldPalette.color(palette.canvas[2]), location: 1)],
                        center: UnitPoint(x: 0.7, y: 0.3), startRadius: 0, endRadius: radius)
                }
                Canvas { context, size in
                    for index in 0..<FeatureLightfield.starCount {
                        // Stable pseudo-random positions prevent stars from jumping on redraw.
                        let x = CGFloat((index * 73 + 29) % 997) / 997 * size.width
                        let y = CGFloat((index * 137 + 83) % 991) / 991 * size.height
                        let opacity = Double((index * 37 + 31) % 100) / 100
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                            with: .color(FeatureLightfieldPalette.color(palette.star).opacity(palette.starOpacity * opacity)))
                    }
                }
                Circle().fill(RadialGradient(stops: [
                    .init(color: FeatureLightfieldPalette.accent(module).opacity(FeatureLightfield.haloCenterOpacity), location: 0),
                    .init(color: FeatureLightfieldPalette.accent(module).opacity(FeatureLightfield.haloMiddleOpacity), location: 0.45),
                    .init(color: .clear, location: 0.72)], center: .center, startRadius: 0, endRadius: geometry.halo.width / 2))
                    .blur(radius: 8)
                    .opacity((phase == .result ? palette.glow * 0.6 : palette.glow) + breath * FeatureLightfieldMotion.haloOpacity)
                    .scaleEffect(1 + CGFloat(breath) * (FeatureLightfieldMotion.haloScale - 1))
                    .lightfieldFrame(geometry.halo.offsetBy(dx: 0, dy: canvasTopInset), probe: "lightfield.halo")
                    .modifier(FeatureLightfieldArtworkMatch(namespace: flowNamespace, id: "lightfield.halo"))
                    // The result halo extends past the sidebar edge; it fades
                    // out inside the canvas instead of being cut at the edge.
                    .mask {
                        GeometryReader { canvas in
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                .init(color: .black, location: min(1, FeatureLightfield.haloEdgeFade / max(1, canvas.size.width)))],
                                startPoint: .leading, endPoint: .trailing)
                        }
                    }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
#if DEBUG
        .layoutProbe("lightfield.backdrop")
#endif
    }
}

struct FeatureLightfieldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let module: ReviewFilter
    var isCancel = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        let accent = FeatureLightfieldPalette.accent(module)
        let shape = RoundedRectangle(cornerRadius: 12)
        configuration.label.font(.system(size: compact ? 13 : 17, weight: .semibold)).labelStyle(.titleOnly)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: compact ? FeatureLightfield.resultActionHeight : nil)
            .foregroundStyle(isCancel ? FeatureLightfieldPalette.resolve(scheme).fg : .white)
            .background {
                if !isCancel {
                    shape.fill(LinearGradient(stops: [.init(color: accent, location: 0),
                        .init(color: FeatureLightfieldPalette.accent(module, secondary: true), location: 1)], startPoint: .top, endPoint: .bottom))
                    shape.fill(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { shape.strokeBorder(accent.opacity(isCancel ? 0.8 : 0.7), lineWidth: 1) }
            .overlay {
                // Inset top highlight (prototype `inset 0 1px 0` white 25%). It
                // follows the rounded shape; a clipped 2 pt bar would poke out
                // past the 12 pt corners as a flat line above the button.
                if !isCancel {
                    shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.25), location: 0),
                        .init(color: .clear, location: 0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .shadow(color: isCancel || compact ? .clear : accent.opacity(0.35), radius: compact ? 0 : 30, y: compact ? 0 : 10)
            .lightfieldComponentProbe("lightfield.primary")
            .padding(.vertical, compact ? (FeatureLightfield.resultActionHitHeight - FeatureLightfield.resultActionHeight) / 2 : 0)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? FeatureLightfieldMotion.pressScale : 1)
            .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.press,
                reduceMotion: reduceMotion || disablesAnimations), value: configuration.isPressed)
    }
}

struct FeatureLightfieldHairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Rectangle().fill(FeatureLightfieldPalette.resolve(scheme).hairColor).frame(height: 1).accessibilityHidden(true) }
}

/// Flat secondary actions share one chrome policy, just like the primary action.
struct FeatureLightfieldRowButtonStyle: ButtonStyle {
    var circular = false
    var minimumHitHeight: CGFloat? = nil
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if circular { configuration.label.frame(minHeight: minimumHitHeight).contentShape(Circle()) }
        else { configuration.label.frame(minHeight: minimumHitHeight).contentShape(Rectangle()) }
    }
}

struct FeatureLightfieldOptions<Rows: View>: View {
    @Environment(\.colorScheme) private var scheme
    var title: String? = nil
    @ViewBuilder let rows: Rows
    var body: some View {
        FeatureOptionsScrollView(probePrefix: "lightfield.options", balancesContent: false, usesLightfield: true) {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).font(.system(size: 13)).tracking(0.26).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .padding(.bottom, 14)
                    FeatureLightfieldHairline()
                }
                rows
#if DEBUG
                Color.clear.frame(height: 1).layoutProbe("lightfield.optionsEnd")
#endif
            }
#if DEBUG
            .layoutProbe("lightfield.options.content")
#endif
        }
    }
}

struct FeatureLightfieldCheck: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let selected: Bool
    let module: ReviewFilter
    var mixed = false
    var accessibilityLabel = ""
    var action: (() -> Void)? = nil
    var body: some View {
        if let action {
            Button(action: action) { glyph }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                // A glyph-only Button must keep its native AXButton/AXPress.
                // Replacing it with an ignored child element produces AXUnknown
                // on macOS 27; represent the same action at the same 20pt frame.
                .accessibilityRepresentation {
                    Button(accessibilityLabel, action: action)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityValue(selected ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
                }
        } else {
            glyph
        }
    }
    private var glyph: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        return RoundedRectangle(cornerRadius: 6)
            .fill(selected ? FeatureLightfieldPalette.accent(module) : .clear)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? .clear : palette.fg.opacity(0.35), lineWidth: 1.5) }
            .overlay {
                Image(systemName: mixed ? "minus" : "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .scaleEffect(selected ? 1 : 0)
                    .animation(FeatureLightfieldMotion.checkAnimation(reduceMotion: reduceMotion || disablesAnimations), value: selected)
            }
            .frame(width: 20, height: 20).accessibilityHidden(true)
    }
}

struct FeatureLightfieldOptionRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var metadata = ""
    var selected = true
    let module: ReviewFilter
    var onToggle: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        Group {
            if let onToggle { Button(action: onToggle) { row }.buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityRepresentation {
                    Toggle(title, isOn: Binding(get: { selected }, set: { _ in onToggle() })).toggleStyle(.checkbox)
                }
                .accessibilityValue(selected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected")) }
            else { row }
        }
        .onHover { hovering = $0 }
        .background(hovering ? FeatureLightfieldPalette.resolve(scheme).hoverColor : .clear)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .accessibilityElement(children: .combine)
    }
    private var row: some View {
        HStack(spacing: 14) {
            FeatureLightfieldCheck(selected: selected, module: module)
            Text(title).font(.system(size: 16)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            Spacer(minLength: 4)
            Text(metadata).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3).lineLimit(1).help(metadata)
        }.frame(height: 56).contentShape(Rectangle())
    }
}

struct FeatureLightfieldProgress<Details: View, Actions: View>: View {
    @Environment(\.colorScheme) private var scheme
    let module: ReviewFilter
    let state: RuntimeWorkflowState
    let title: String
    let subtitle: String?
    let fraction: Double?
    let currentItem: String?
    let metrics: [RuntimeWorkflowMetric]
    let elapsed: String
    @ViewBuilder let details: Details
    @ViewBuilder let actions: Actions

    private var visibleMetrics: [RuntimeWorkflowMetric] {
        metrics.count > 2 ? [metrics[0], metrics[metrics.count - 1]] : metrics
    }

    private var auxiliaryValue: String {
        let hiddenMetrics: [String] = metrics.count > 2
            ? metrics.dropFirst().dropLast().map { $0.title + " · " + $0.value } : []
        return (hiddenMetrics + [elapsed]).joined(separator: ", ")
    }

    private var compactAccessibilityValue: String {
        let facts: [String] = [subtitle, currentItem].compactMap { $0 }
        let allMetrics = metrics.map { $0.title + " · " + $0.value }
        let progress = RuntimeWorkflowState.measuredFraction(fraction).map { "\(Int($0 * 100))%" }
            ?? L10n.text("未提供进度", "Progress unavailable")
        return ([progress] + facts + allMetrics + [elapsed]).joined(separator: ", ")
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            progressContent.fixedSize(horizontal: false, vertical: true)
            FeatureOptionsScrollView(probePrefix: "lightfield.progress", balancesContent: false,
                usesLightfield: true, showsOverflowHint: false) {
                progressContent
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.title + " · " + title)
            .accessibilityValue(compactAccessibilityValue)
        }
#if DEBUG
        .layoutProbe("lightfield.progress.viewport")
#endif
    }

    private var progressContent: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        let measured = RuntimeWorkflowState.measuredFraction(fraction)
        return VStack(alignment: .leading, spacing: 0) {
                Text(state == .running ? title : state.title + " · " + title)
                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
                    .accessibilityLabel(state.title + " · " + title)
                    .accessibilityValue(auxiliaryValue)
#if DEBUG
                    .layoutProbe("runtime.stage")
                    .lightfieldRenderedProbe(["runtimeState": state.title, "stage": title, "subtitle": subtitle ?? ""])
#endif
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.fg2)
                        .lineLimit(1).help(subtitle)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(measured.map { String(Int($0 * 100)) } ?? "—").font(.system(size: 64, weight: .bold)).monospacedDigit()
                    // Unknown progress shows "—" alone; a unit after it would read as a value.
                    if measured != nil {
                        Text("%").font(.system(size: 24, weight: .semibold)).foregroundStyle(FeatureLightfieldPalette.accent(module))
#if DEBUG
                            .layoutProbe("lightfield.progress.unit")
#endif
                    }
                }.foregroundStyle(palette.fg).padding(.top, 10)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.hairColor)
                        if let measured {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [FeatureLightfieldPalette.accent(module, secondary: true), FeatureLightfieldPalette.accent(module)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * CGFloat(measured))
                                .shadow(color: FeatureLightfieldPalette.accent(module), radius: 12)
                        }
                    }
                }.frame(height: 4).padding(.top, 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("进度", "Progress"))
                .accessibilityValue(measured.map { "\(Int($0 * 100))%" } ?? L10n.text("未提供进度", "Progress unavailable"))
#if DEBUG
                .layoutProbe("runtime.progress")
#endif
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Text(L10n.text("当前项 ·", "Current Item ·")).fixedSize(horizontal: true, vertical: false)
                        Text(currentItem ?? L10n.text("未提供当前项", "Current item unavailable"))
                            .lineLimit(1).truncationMode(.middle).help(currentItem ?? "")
                            .accessibilityLabel(currentItem ?? L10n.text("未提供当前项", "Current item unavailable"))
#if DEBUG
                            .layoutProbe(LayoutProbeID.runtimeLocation)
#endif
                    }
                    ForEach(visibleMetrics) { metric in
                        (Text(metric.title + " · ").foregroundColor(palette.fg2) + Text(metric.value).foregroundColor(palette.fg).bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .accessibilityLabel(metric.title + " · " + metric.value)
                    }
                    if visibleMetrics.count < 2 {
                        Text(elapsed)
#if DEBUG
                            .layoutProbe("runtime.elapsed")
#endif
                    }
                    details
                    actions
                }.font(.system(size: 15)).foregroundStyle(palette.fg2).padding(.top, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FeatureLightfieldResults<Rows: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    let module: ReviewFilter
    let label: String
    let value: Double?
    let unit: String
    var precision = 0
    var secondary: [LightfieldMetric] = []
    var metrics: [LightfieldMetric] = []
    @ViewBuilder let rows: Rows
    var body: some View {
        LightfieldResultContent(shortSummaryOverlay: AnyView(shortSummaryArtwork), rowsHaveBlankTopBand: true, usesLazyRows: false,
            listHeader: AnyView(listHeader)) {
            summary
        } rows: {
            rows
        }
    }
    private var shortSummaryArtwork: some View {
        FeatureLightfieldArtwork(art: GeneratedArt.module(for: module), variant: .landing)
            .frame(width: 76, height: 76)
#if DEBUG
            .layoutProbe("lightfield.artwork")
#endif
    }
    @ViewBuilder private var summary: some View {
        if compactResults || !secondary.isEmpty {
            LightfieldSummary(module: module, label: label,
                value: value.map { String(format: "%.*f", precision, $0) } ?? "—", unit: unit,
                secondary: secondary, showsArtwork: false)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1).help(label)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FeatureLightfieldNumber(value: value, precision: precision)
                    Text(unit).font(.system(size: 24, weight: .semibold)).foregroundStyle(FeatureLightfieldPalette.accent(module))
                }
            }.padding(.leading, 96).frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        }
    }
    private var listHeader: some View {
        VStack(spacing: 0) {
            FeatureLightfieldHairline()
            if !metrics.isEmpty {
                LightfieldMetricGroup(metrics: metrics, style: .inline, probeID: "lightfield.updater.metrics")
                FeatureLightfieldHairline()
            }
        }
    }
}

private struct FeatureLightfieldNumber: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @State private var startedAt: Date? = Date()
    let value: Double?
    let precision: Int
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || disablesAnimations || startedAt == nil)) { context in
            let duration = FeatureLightfieldMotion.duration(FeatureLightfieldMotion.number, reduceMotion: reduceMotion || disablesAnimations)
            let elapsed = startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? duration
            let progress = duration == 0 ? 1 : min(1, elapsed / duration)
            let displayed = value.flatMap { $0.isFinite ? $0 * (1 - pow(1 - progress, 3)) : nil }
            Text(displayed.map { String(format: "%.*f", precision, $0) } ?? "—")
                .font(.system(size: 52, weight: .bold)).monospacedDigit().foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
                .accessibilityLabel(value.map { String(format: "%.*f", precision, $0) } ?? L10n.text("未提供", "Unavailable"))
        }
        .task(id: value) {
            guard !reduceMotion, !disablesAnimations else { startedAt = nil; return }
            startedAt = Date()
            try? await Task.sleep(for: .seconds(FeatureLightfieldMotion.number))
            if !Task.isCancelled { startedAt = nil }
        }
    }
}

enum FeatureLightfieldStatus: String, Sendable { case normal, warning, failure, unknown
    func color(_ palette: FeatureLightfieldPalette) -> Color {
        switch self {
        case .normal: FeatureLightfieldPalette.color(palette.normal)
        case .warning: FeatureLightfieldPalette.color(palette.warning)
        case .failure: FeatureLightfieldPalette.color(palette.failure)
        case .unknown: palette.fg3
        }
    }
    var symbol: String {
        switch self { case .normal: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failure: "xmark.circle.fill"; case .unknown: "questionmark.circle" }
    }
}

/// Four proportional columns; selection lives at the call site. Menus, real
/// object icons and status symbols may be supplied, never decorative glyphs.
/// An optional 20 pt trailing column holds a row-end disclosure (D67); it is
/// inside the row so the hairline and the four columns stay continuous.
struct FeatureLightfieldResultRow<Leading: View, Trailing: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldReportsRowTops) private var reportsRowTops
    let title: String
    let detail: String
    let value: String
    var status: FeatureLightfieldStatus? = nil
    var reservesTrailing = false
    /// A short reason shown beside the path in the warning colour (for
    /// example “所属应用运行中”). It never truncates; the path yields first.
    var note: String? = nil
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    init(title: String, detail: String, value: String, status: FeatureLightfieldStatus? = nil,
         reservesTrailing: Bool, note: String? = nil,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.value = value
        self.status = status
        self.reservesTrailing = reservesTrailing
        self.note = note
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        // A Layout (not a GeometryReader) computes the four proportional
        // columns from the proposed width, so long lists stay cheap.
        FeatureLightfieldRowColumns(reservesTrailing: reservesTrailing) {
            leading.frame(width: 20, height: 20)
            Text(title).font(.system(size: 15)).lineLimit(1).help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(detail).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(palette.fg3)
                    .lineLimit(1).truncationMode(.middle).help(detail)
                if let note, !note.isEmpty {
                    Text(note).font(.system(size: 12.5)).lineLimit(1).fixedSize()
                        .foregroundStyle(palette.warningColor).layoutPriority(1)
#if DEBUG
                        .layoutProbe("lightfield.note." + title)
#endif
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(value).font(.system(size: 15)).monospacedDigit().lineLimit(1)
                .truncationMode(.middle).help(value).accessibilityLabel(value)
                .foregroundStyle(status?.color(palette) ?? palette.fg)
                .frame(maxWidth: .infinity, alignment: .trailing)
#if DEBUG
                .layoutProbe("lightfield.value." + title)
#endif
            if reservesTrailing {
                trailing.frame(width: FeatureLightfield.disclosureColumn, height: 20)
            }
        }
        .foregroundStyle(palette.fg)
        .frame(height: FeatureLightfield.rowHeight)
        .background(hovering ? palette.hoverColor : .clear)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .background {
            if reportsRowTops {
                GeometryReader { row in
                    Color.clear.preference(key: FeatureLightfieldRowTopKey.self,
                        value: [row.frame(in: .named(FeatureLightfield.resultsDocumentSpace)).minY])
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Columns of a result row: check/status 20 | title 1.2 | path 2 | value 96
/// (72 when compact) | optional 20 pt disclosure, 16 pt gaps, 6 pt trailing.
struct FeatureLightfieldRowColumns: Layout {
    let reservesTrailing: Bool

    func widths(for width: CGFloat) -> [CGFloat] {
        let compact = width < 520
        let numberWidth: CGFloat = compact ? 72 : 96
        let trailingWidth: CGFloat = reservesTrailing ? FeatureLightfield.disclosureColumn + 16 : 0
        let remaining = max(0, width - 20 - numberWidth - 48 - 6 - trailingWidth)
        var result: [CGFloat] = [20, remaining * 1.2 / 3.2, remaining * 2 / 3.2, numberWidth]
        if reservesTrailing { result.append(FeatureLightfield.disclosureColumn) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 520, height: FeatureLightfield.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (index, width) in widths(for: bounds.width).enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: index == 0 || index == 4 ? 20 : bounds.height))
            x += width + 16
        }
    }
}

struct FeatureLightfieldRowTopKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

private struct FeatureLightfieldReportsRowTopsKey: EnvironmentKey { static let defaultValue = false }
private struct FeatureOperationHistoryActionKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}
extension EnvironmentValues {
    /// Opens the main window's operation history; nil hides the page entry.
    var featureOperationHistoryAction: (() -> Void)? {
        get { self[FeatureOperationHistoryActionKey.self] }
        set { self[FeatureOperationHistoryActionKey.self] = newValue }
    }
}
extension EnvironmentValues {
    /// Set only inside a snapped result list, so rows elsewhere do no geometry work.
    var featureLightfieldReportsRowTops: Bool {
        get { self[FeatureLightfieldReportsRowTopsKey.self] }
        set { self[FeatureLightfieldReportsRowTopsKey.self] = newValue }
    }
}

extension FeatureLightfieldResultRow where Trailing == EmptyView {
    init(title: String, detail: String, value: String, status: FeatureLightfieldStatus? = nil,
         note: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, detail: detail, value: value, status: status, reservesTrailing: false,
            note: note, leading: leading, trailing: { EmptyView() })
    }
}

/// The only row-end disclosure arrow. It is a control affordance (D64), not
/// decoration, and is hidden from VoiceOver because its row publishes the
/// expanded/collapsed value.
struct FeatureLightfieldDisclosureChevron: View {
    let expanded: Bool
    var probe: String? = nil
    var body: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: FeatureLightfield.disclosureColumn, height: 20)
            .accessibilityHidden(true)
#if DEBUG
            .layoutProbe(probe ?? "lightfield.disclosure")
#endif
    }
}

/// Status-type row (D67 §2): 20×20 status symbol in the selection column,
/// short semantic status in the last column, and a reserved row-end
/// disclosure column so every status row in a list keeps the same grid.
struct FeatureLightfieldStatusRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let detail: String
    let value: String
    let status: FeatureLightfieldStatus
    var leadingProbe: String? = nil
    var expanded: Bool? = nil
    var disclosureProbe: String? = nil
    var body: some View {
        FeatureLightfieldResultRow(title: title, detail: detail, value: value, status: status, reservesTrailing: true) {
            // D67: the status symbol is a 20×20 first-column glyph, the same
            // box as the selection check, so the columns align across pages.
            LightfieldStatusGlyph(featureStatus: status)
                .accessibilityHidden(true)
#if DEBUG
                .layoutProbe(leadingProbe ?? "lightfield.status.leading")
#endif
        } trailing: {
            if let expanded { FeatureLightfieldDisclosureChevron(expanded: expanded, probe: disclosureProbe) }
        }.accessibilityElement(children: .combine)
        .accessibilityLabel(title + " · " + detail + " · " + value)
#if DEBUG
        .lightfieldRenderedProbe(["health." + title: value, "healthTone." + title: status.rawValue])
#endif
    }
}

/// Whole-row disclosure for status rows. Evidence stays collapsed until the
/// row is opened. A native DisclosureGroup is not used: restyled for the
/// row-end arrow, macOS 27 publishes it as an AXDisclosureTriangle without
/// AXPress, so VoiceOver could not open it. This button publishes press,
/// the short status in its label and the expanded state in its value.
struct FeatureLightfieldStatusDisclosure<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @State private var expanded = false
    let title: String
    let detail: String
    let value: String
    let status: FeatureLightfieldStatus
    var leadingProbe: String? = nil
    var disclosureProbe: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
                    reduceMotion: reduceMotion || disablesAnimations)) { expanded.toggle() }
            } label: {
                FeatureLightfieldStatusRow(title: title, detail: detail, value: value, status: status,
                    leadingProbe: leadingProbe, expanded: expanded, disclosureProbe: disclosureProbe)
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(title + " · " + value)
            .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
            .accessibilityHint(detail)
            if expanded {
                content.font(.system(size: 13))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                    .padding(.leading, 36).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FeatureLightfieldRowEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @State private var appeared = false
    let index: Int
    func body(content: Content) -> some View {
        let instant = reduceMotion || disablesAnimations
        content.opacity(instant || appeared ? 1 : 0)
            .offset(y: instant || appeared ? 0 : FeatureLightfieldMotion.rowDistance)
            .onAppear { withAnimation(FeatureLightfieldMotion.rowAnimation(index: index, reduceMotion: instant)) { appeared = true } }
    }
}

extension View {
    func lightfieldRowEntrance(_ index: Int) -> some View { modifier(FeatureLightfieldRowEntrance(index: index)) }
    fileprivate func lightfieldFrame(_ frame: CGRect, probe: String) -> some View {
        self.frame(width: frame.width, height: frame.height, alignment: .topLeading)
#if DEBUG
            .layoutProbe(probe)
#endif
            .position(x: frame.midX, y: frame.midY)
    }
}
#if DEBUG
struct FeatureLightfieldRenderedPreferenceKey: PreferenceKey {
    static let defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func lightfieldRenderedProbe(_ values: [String: String]) -> some View { preference(key: FeatureLightfieldRenderedPreferenceKey.self, value: values) }
}
#endif

struct FeatureLightfieldPhasePreferenceKey: PreferenceKey {
    static let defaultValue: FeatureLightfieldPhase = .landing
    static func reduce(value: inout FeatureLightfieldPhase, nextValue: () -> FeatureLightfieldPhase) {
        value = nextValue()
    }
}

private struct FeatureLightfieldBackdropProvidedKey: EnvironmentKey { static let defaultValue = false }
private struct FeatureLightfieldModuleKey: EnvironmentKey { static let defaultValue: ReviewFilter? = nil }
extension EnvironmentValues {
    var featureLightfieldBackdropProvided: Bool {
        get { self[FeatureLightfieldBackdropProvidedKey.self] }
        set { self[FeatureLightfieldBackdropProvidedKey.self] = newValue }
    }
    var featureLightfieldModule: ReviewFilter? {
        get { self[FeatureLightfieldModuleKey.self] }
        set { self[FeatureLightfieldModuleKey.self] = newValue }
    }
}

struct FeatureLightfieldHealthOptions: View {
    let availability: InternalBatteryAvailability
    var body: some View {
        FeatureLightfieldOptions(title: L10n.text("检查项目", "Check Items")) {
            FeatureLightfieldOptionRow(title: L10n.text("磁盘", "Disk"), metadata: "SMART", module: .healthHub)
            if availability != .absent {
                FeatureLightfieldOptionRow(title: L10n.text("电池", "Battery"),
                    metadata: availability == .unknown ? L10n.text("内置电池待确认", "Internal battery not confirmed") : "",
                    module: .healthHub)
            }
            FeatureLightfieldOptionRow(title: L10n.text("系统状态", "System State"),
                metadata: L10n.text("稳定性与备份", "Stability & Backup"), module: .healthHub)
        }
    }
}

enum FeatureLightfieldScanState {
    static func text(_ state: CleanupScanRuleState) -> String {
        switch state {
        case .pending: L10n.text("等待", "Pending")
        case .scanning: L10n.text("扫描中", "Scanning")
        case .clean: L10n.text("无候选", "No candidates")
        case .found: L10n.text("已发现", "Found")
        case .skipped: L10n.text("已跳过", "Skipped")
        case .failed: L10n.text("未完成", "Not completed")
        }
    }
}

struct FeatureLightfieldAmount: Equatable {
    let value: Double?
    let unit: String
    let precision: Int
    let qualifier: String
    static func parse(_ formatted: String) -> Self {
        let pieces = formatted.split(separator: " ").map(String.init)
        guard pieces.count >= 2, let number = Double(pieces[pieces.count - 2]), number.isFinite else {
            return Self(value: nil, unit: "", precision: 0, qualifier: formatted)
        }
        return Self(value: number, unit: pieces.last ?? "", precision: pieces[pieces.count - 2].contains(".") ? 1 : 0,
            qualifier: pieces.dropLast(2).joined(separator: " "))
    }
}
