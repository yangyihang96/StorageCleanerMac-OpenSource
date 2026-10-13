import AppKit
import SwiftUI

/// The D67 skeleton remains the owner of colors, motion, row dimensions and
/// checkbox/button styles. B2 adds content primitives only; no store actions.
struct LightfieldOptionIconView: View {
    @Environment(\.generatedArtWindowVisible) private var artWindowVisible
    @Environment(\.displayScale) private var displayScale
    let icon: LightfieldOptionIcon
    var library: GeneratedArtLibrary = LightfieldOptionIcon.library
    /// Drawn size; defaults to the 28 pt option slot.
    var pointSize: CGFloat = LightfieldOptionIcon.pointSize
    var resourceNameOverride: String? = nil
    @State private var image: CGImage?
    private var resource: String {
        resourceNameOverride ?? icon.resourceName(LightfieldOptionIcon.variant(pointSize: pointSize, displayScale: displayScale))
    }
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFit()
                    .lightfieldComponentProbe("lightfield.option.loaded." + resource)
            } else {
                // Missing art shows nothing but keeps the 28 pt slot, so rows align.
                Color.clear
            }
        }
        .frame(width: pointSize, height: pointSize)
        .accessibilityHidden(true)
        .task(id: GeneratedArtLoadRequest(name: resource, visible: artWindowVisible)) {
            guard artWindowVisible else { return }
            image = nil
            let loaded = await library.image(named: resource)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct LightfieldOptionRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let icon: LightfieldOptionIcon
    let module: ReviewFilter
    /// nil is a fixed informational row, with no checkbox or AX press action.
    var selection: Binding<Bool>? = nil
    /// Always-included scan scope: informational, never a toggle or AXPress.
    var isIncluded = false
    var metadata = ""
    var probeID = "lightfield.option"
    @State private var hovering = false
    var body: some View {
        Group {
            if let selection {
                Button { selection.wrappedValue.toggle() } label: { row }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    // As FeatureLightfieldStatusDisclosure: a Button wrapped in
                    // accessibilityElement(children: .ignore) loses AXPress on macOS 27.
                    .accessibilityLabel(title)
                    .accessibilityValue(selection.wrappedValue ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
                    .accessibilityHint(metadata)
            } else {
                row.accessibilityElement(children: .ignore)
                    .accessibilityLabel(title + (metadata.isEmpty ? "" : " · " + metadata))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .background(hovering && selection != nil ? FeatureLightfieldPalette.resolve(scheme).hoverColor : .clear)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .lightfieldComponentProbe(probeID)
    }
    private var row: some View {
        HStack(spacing: 14) {
            if let selection { FeatureLightfieldCheck(selected: selection.wrappedValue, module: module) }
            else if isIncluded { FeatureLightfieldCheck(selected: true, module: module).accessibilityHidden(true) }
            LightfieldOptionIconView(icon: icon).lightfieldComponentProbe(probeID + ".icon")
            Text(title).font(.system(size: 16)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
                .lineLimit(1).truncationMode(.tail).help(title).frame(maxWidth: .infinity, alignment: .leading)
                .lightfieldComponentProbe(probeID + ".title")
            if !metadata.isEmpty {
                Text(metadata).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                    .lineLimit(1).truncationMode(.middle).help(metadata).frame(maxWidth: 140, alignment: .trailing)
                    .lightfieldComponentProbe(probeID + ".metadata")
            }
        }.padding(.trailing, 6).frame(height: FeatureLightfield.optionHeight).contentShape(Rectangle())
    }
}

struct LightfieldAppIcon: View {
    enum Size: Int, CaseIterable { case small = 16, medium = 24, large = 28 }
    @Environment(\.colorScheme) private var scheme
    var path: String? = nil
    var processIdentifier: Int32? = nil
    var size: Size = .medium
    var accessibilityName: String? = nil
    @State private var runningIcon: NSImage?
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    var body: some View {
        ZStack {
            if let runningIcon {
                Image(nsImage: runningIcon).resizable().scaledToFit()
            } else {
                CachedAppIconView(path: path ?? "", size: CGFloat(size.rawValue), isDecorative: accessibilityName == nil) {
                    Image(systemName: "gearshape.fill").resizable().scaledToFit()
                        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                }
            }
        }
        .frame(width: CGFloat(size.rawValue), height: CGFloat(size.rawValue))
        .accessibilityHidden(accessibilityName == nil)
        .accessibilityLabel(accessibilityName ?? "")
        .task(id: "\(path ?? "")#\(processIdentifier ?? 0)") {
            runningIcon = nil
#if DEBUG
            guard !isFixture else { return }
#endif
            // A PID may have been reused since capture. Only take its icon
            // when its bundle still belongs to the captured application.
            guard let processIdentifier, let path, path.hasSuffix(".app"),
                  let application = NSRunningApplication(processIdentifier: processIdentifier),
                  let bundle = application.bundleURL?.path,
                  bundle == path || bundle.hasPrefix(path + "/") else { return }
            runningIcon = application.icon
        }
    }
}

/// Aliases do not add another state catalog or change legacy MetadataPill's
/// `.none` semantics. Only the glyph interprets no restriction as normal.
extension MetadataPillStatus {
    static var normal: Self { .none }
    static var systemOnly: Self { .systemSettingsOnly }
    var lightfieldSymbol: String { systemImage ?? "checkmark.circle.fill" }
    var lightfieldDescription: String {
        self == .none ? L10n.text("正常", "Normal") : accessibilityDescription
    }
    func lightfieldColor(_ palette: FeatureLightfieldPalette) -> Color {
        switch self {
        case .none: FeatureLightfieldStatus.normal.color(palette)
        case .warning: FeatureLightfieldStatus.warning.color(palette)
        case .failure: FeatureLightfieldStatus.failure.color(palette)
        case .locked, .readOnly, .systemSettingsOnly: palette.fg3
        }
    }
}

struct LightfieldStatusGlyph: View {
    @Environment(\.colorScheme) private var scheme
    let status: MetadataPillStatus
    var symbol: String? = nil
    var color: Color? = nil
    private var featureStatus: FeatureLightfieldStatus? = nil
    var tone: FeatureLightfieldStatus? = nil
    init(status: MetadataPillStatus, symbol: String? = nil, color: Color? = nil,
         tone: FeatureLightfieldStatus? = nil) {
        self.status = status
        self.symbol = symbol
        self.color = color
        self.tone = tone
    }
    init(featureStatus: FeatureLightfieldStatus) {
        self.status = .none
        self.featureStatus = featureStatus
    }
    var body: some View {
        Image(systemName: symbol ?? featureStatus?.symbol ?? status.lightfieldSymbol).resizable().scaledToFit()
            .foregroundStyle(color ?? featureStatus?.color(FeatureLightfieldPalette.resolve(scheme))
                ?? tone?.color(FeatureLightfieldPalette.resolve(scheme))
                ?? status.lightfieldColor(FeatureLightfieldPalette.resolve(scheme)))
            .frame(width: FeatureLightfield.checkSide, height: FeatureLightfield.checkSide)
            .accessibilityElement(children: .ignore).accessibilityLabel(featureStatus?.accessibilityDescription ?? status.lightfieldDescription)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension FeatureLightfieldStatus {
    var accessibilityDescription: String {
        switch self {
        case .normal: L10n.text("正常", "Normal")
        case .warning: L10n.text("警告", "Warning")
        case .failure: L10n.text("失败", "Failure")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }
}

struct LightfieldRingGeometry: Equatable {
    let diameter: CGFloat
    let stroke: CGFloat
    /// 57% is the approved CSS center. Also constrain to the inner track's
    /// inscribed square: every corner is inside the circle, at all diameters.
    let textBounds: CGRect
    init(diameter: CGFloat) {
        self.diameter = diameter.isFinite ? max(1, diameter) : 1
        stroke = min(6, self.diameter * 0.06)
        let side = min(self.diameter * 0.57, max(0, self.diameter - 2 * stroke) / sqrt(2))
        textBounds = CGRect(x: (self.diameter - side) / 2, y: (self.diameter - side) / 2, width: side, height: side)
    }
}

/// Fit the whole baseline (number + unit), rather than independently shrinking
/// two siblings no further than 80%. B0's 81% at 820×560 is the regression case.
@MainActor
struct LightfieldRingTypography {
    let valueSize: CGFloat
    let unitSize: CGFloat
    let labelSize: CGFloat
    init(geometry: LightfieldRingGeometry, value: String, unit: String, label: String, status: Bool) {
        let height = geometry.textBounds.height
        let numberHeight = height * (label.isEmpty ? 0.86 : 0.64)
        let number = min(34, min(geometry.diameter * 34 / 76, numberHeight * 0.9))
        let suffix = min(15, min(geometry.diameter * 15 / 76, numberHeight * 0.6))
        // Optical sizes and fallback CJK fonts are not linear in point size.
        // Measure at each candidate size rather than scaling one measurement.
        let scale = Self.fittedScale(width: geometry.textBounds.width - 2) { ratio in
            let numberWidth = (value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: number * ratio, weight: .bold)]).width
            let unitWidth = unit.isEmpty ? 0 : (unit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: suffix * ratio, weight: .medium)]).width + 2
            return numberWidth + unitWidth
        }
        valueSize = number * scale
        unitSize = suffix * scale
        let caption = min(status ? 15 : 13, min(geometry.diameter * (status ? 15 : 13) / 76, height * 0.27 * 0.9))
        labelSize = caption * Self.fittedScale(width: geometry.textBounds.width) { ratio in
            (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: caption * ratio, weight: status ? .semibold : .regular)]).width
        }
    }
    private static func fittedScale(width: CGFloat, measure: (CGFloat) -> CGFloat) -> CGFloat {
        if measure(1) <= width { return 1 }
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<20 {
            let candidate = (lower + upper) / 2
            if measure(candidate) <= width { lower = candidate } else { upper = candidate }
        }
        return lower
    }
}

struct LightfieldRing: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let diameter: CGFloat
    /// nil means unavailable, never a measured zero.
    let progress: Double?
    let color: Color
    let value: String
    var unit = ""
    var label = ""
    /// A status word ("正常") under the number: 15 pt semibold in the ring colour,
    /// as the approved memory ring; otherwise a 13 pt secondary caption.
    var labelIsStatus = false
    var probeID = "lightfield.ring"
    var body: some View {
        let geometry = LightfieldRingGeometry(diameter: diameter)
        let palette = FeatureLightfieldPalette.resolve(scheme)
        let typography = LightfieldRingTypography(geometry: geometry, value: value, unit: unit, label: label, status: labelIsStatus)
        let numberHeight = geometry.textBounds.height * (label.isEmpty ? 0.86 : 0.64)
        let labelHeight = geometry.textBounds.height * 0.27
        ZStack {
            Circle().stroke(palette.hairColor, lineWidth: geometry.stroke)
            if let progress, progress.isFinite {
                Circle().trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: geometry.stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: min(2, geometry.textBounds.height * 0.05)) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: typography.valueSize, weight: .bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.1) // lightfield-scale-ok: ring-fitted-value
                        .lightfieldComponentProbe(probeID + ".value")
                    if !unit.isEmpty {
                        Text(unit).font(.system(size: typography.unitSize, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.1) // lightfield-scale-ok: ring-fitted-unit
                            .lightfieldComponentProbe(probeID + ".unit")
                    }
                }.frame(maxWidth: .infinity).frame(height: numberHeight)
                if !label.isEmpty {
                    Text(label).font(.system(size: typography.labelSize, weight: labelIsStatus ? .semibold : .regular))
                        .foregroundStyle(labelIsStatus ? color : palette.fg2).lineLimit(1).minimumScaleFactor(0.1) // lightfield-scale-ok: ring-fitted-label
                        .frame(maxWidth: .infinity).frame(height: labelHeight)
                        .lightfieldComponentProbe(probeID + ".label")
                }
            }
            .foregroundStyle(palette.fg)
            .frame(width: geometry.textBounds.width, height: geometry.textBounds.height)
            .lightfieldComponentProbe(probeID + ".text")
        }
        .padding(geometry.stroke / 2)
        .frame(width: geometry.diameter, height: geometry.diameter)
        .lightfieldComponentProbe(probeID)
        .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.number,
            reduceMotion: reduceMotion || disablesAnimations), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, value, unit].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct LightfieldMetric: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    var unit = ""
    var status: FeatureLightfieldStatus? = nil
    var caption = ""
    var valuePrefix = ""
}

struct LightfieldMetricGroup: View {
    enum Style: Equatable { case stacked, inline }
    @Environment(\.colorScheme) private var scheme
    let metrics: [LightfieldMetric]
    var showsLabels = true
    var style: Style = .stacked
    var probeID = "lightfield.metrics"
    @ViewBuilder
    var body: some View {
        if style == .inline {
            LightfieldInlineMetricsLayout {
                ForEach(metrics) { metric in
                    LightfieldInlineMetricLayout {
                        (Text(metric.value).font(.system(size: 24, weight: .semibold))
                            .foregroundColor(metric.status?.color(FeatureLightfieldPalette.resolve(scheme)) ?? FeatureLightfieldPalette.resolve(scheme).fg)
                            + Text(metric.unit.isEmpty ? "" : " " + metric.unit).font(.system(size: 15))
                                .foregroundColor(FeatureLightfieldPalette.resolve(scheme).fg2))
                            .monospacedDigit().fixedSize()
                            .lightfieldComponentProbe(probeID + ".value." + metric.id)
                        Text(metric.label).font(.system(size: 13))
                            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).fixedSize()
                            .lightfieldComponentProbe(probeID + ".label." + metric.id)
                    }
                    .lightfieldComponentProbe(probeID + ".column." + metric.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(metric.label + " · " + metric.value + " " + metric.unit)
                }
            }.lightfieldComponentProbe(probeID)
        } else {
            stackedMetrics
        }
    }
    private var stackedMetrics: some View {
        GeometryReader { proxy in
            let gap = min(24, proxy.size.width / CGFloat(max(1, metrics.count)) * 0.1)
            let width = max(0, (proxy.size.width - gap * CGFloat(max(0, metrics.count - 1))) / CGFloat(max(1, metrics.count)))
            HStack(alignment: .top, spacing: gap) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        if showsLabels { Text(metric.label).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                            .lineLimit(1).truncationMode(.tail).help(metric.label)
                            .lightfieldComponentProbe(probeID + ".label." + metric.id) }
                        stackedValue(metric)
                    }.frame(width: width, alignment: .leading).clipped()
                    .lightfieldComponentProbe(probeID + ".column." + metric.id)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(metric.label + " · " + metric.value + " " + metric.unit)
                }
            }
        }.frame(height: showsLabels ? 58 : 22).lightfieldComponentProbe(probeID)
    }
    private func stackedValue(_ metric: LightfieldMetric) -> some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        return (Text(metric.value).font(.system(size: showsLabels ? 22 : 15, weight: .semibold))
            .foregroundColor(metric.status?.color(palette) ?? palette.fg)
            + Text(metric.unit.isEmpty ? "" : " " + metric.unit).font(.system(size: 15)).foregroundColor(palette.fg2))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: metric-value
            .frame(maxWidth: .infinity, alignment: showsLabels ? .leading : .trailing)
            .lightfieldComponentProbe(probeID + ".value." + metric.id)
    }
}

/// The bounded path column used by later application/file batches.
struct LightfieldPathText: View {
    @Environment(\.colorScheme) private var scheme
    let path: String
    var body: some View {
        Text(path).font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
            .lineLimit(1).truncationMode(.middle).help(path)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(path)
    }
}

struct LightfieldDataBar: View {
    enum Style: Equatable { case ratio, share, progress(segments: Int = 0)
        var height: CGFloat { switch self { case .ratio: 2; case .share: 3; case .progress: 6 } }
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let progress: Double?
    let module: ReviewFilter
    var style: Style = .ratio
    var color: Color? = nil
    var accessibilityLabel = L10n.text("进度", "Progress")
    var status: FeatureLightfieldStatus? = nil
    var body: some View {
        GeometryReader { proxy in
            let fraction = LightfieldChartGeometry.fraction(progress)
            let accent = status?.color(.resolve(scheme)) ?? color ?? FeatureLightfieldPalette.accent(module)
            // Approved run track: accent2 → accent with a soft accent glow;
            // the inline ratio bar is a flat 60% accent.
            let gradient = LinearGradient(colors: [FeatureLightfieldPalette.accent(module, secondary: true), accent],
                startPoint: .leading, endPoint: .trailing)
            let track = FeatureLightfieldPalette.resolve(scheme).hairColor
            if case .progress(let count) = style, count > 0 {
                // 3 pt gaps, each cell its own capsule. Cell shade runs accent2
                // (first cell) → accent (last cell) across the whole track, as
                // the approved run page. Cells are static; only the current one
                // is a separate breathing view (review P2-4), so a frame tick
                // redraws one cell, never the track.
                let gap = min(3, proxy.size.width / CGFloat(count * 2))
                let cell = max(0, (proxy.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                let breathing = Set(LightfieldChartGeometry.breathingSegments(count: count, progress: progress))
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        let state = LightfieldChartGeometry.segment(index: index, count: count, progress: progress)
                        let fill = Rectangle().fill(gradient).frame(width: proxy.size.width)
                            .offset(x: -CGFloat(index) * (cell + gap)).frame(width: cell, alignment: .leading)
                            .clipShape(Capsule()).shadow(color: accent.opacity(0.45), radius: 6)
                        ZStack {
                            Capsule().fill(track)
                            if breathing.contains(index) {
                                LightfieldBreathingCell(instant: reduceMotion || disablesAnimations) { fill }
                            } else if state != .pending {
                                fill
                            }
                        }.frame(width: cell)
                    }
                }
            } else if style == .ratio || style == .share {
                ZStack(alignment: .leading) {
                    Rectangle().fill(track)
                    if let fraction { Rectangle().fill(accent.opacity(0.6)).frame(width: proxy.size.width * fraction) }
                }.clipShape(Capsule())
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if let fraction {
                        Capsule().fill(gradient).frame(width: proxy.size.width * fraction)
                            .shadow(color: accent.opacity(0.45), radius: 6)
                    }
                }
            }
        }
        .frame(height: style.height)
        .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
            reduceMotion: reduceMotion || disablesAnimations), value: progress)
        .accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel)
        .accessibilityValue(LightfieldChartGeometry.fraction(progress).map { "\(Int($0 * 100))%" } ?? L10n.text("未提供", "Unavailable"))
    }
}

/// The only animated part of a segmented bar: one cell.
private struct LightfieldBreathingCell<Content: View>: View {
    let instant: Bool
    @ViewBuilder let content: Content
    var body: some View { content.modifier(LightfieldBarPulse(active: true, instant: instant)) }
}

private struct LightfieldBarPulse: ViewModifier {
    let active: Bool
    let instant: Bool
    func body(content: Content) -> some View {
        TimelineView(.animation(paused: instant || !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate / FeatureLightfieldMotion.halo * 2 * .pi
            content.opacity(instant || !active ? 1 : 0.725 + 0.275 * cos(phase))
        }
    }
}

struct LightfieldExpandableRow<Leading: View, Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let title: String
    var metadata = ""
    var subtitle = ""
    var trailing: AnyView? = nil
    var rowHeight: CGFloat = FeatureLightfield.rowHeight
    var reportsCompactBoundaries = false
    var probeID = "lightfield.expandable"
    @Binding var expanded: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
                    reduceMotion: reduceMotion || disablesAnimations)) { expanded.toggle() }
            } label: {
                HStack(spacing: 16) {
                    leading
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(title)
                            .lightfieldComponentProbe(probeID + ".title")
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                                .lineLimit(1).truncationMode(.tail).help(subtitle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let trailing { trailing }
                    else { Text(metadata).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3).lineLimit(1) }
                    FeatureLightfieldDisclosureChevron(expanded: expanded)
                }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
                .frame(height: rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle()).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
            .accessibilityHint(metadata)
            .lightfieldResultRowBoundary(isEnabled: reportsCompactBoundaries)
            if expanded { content.padding(.leading, FeatureLightfield.childRowIndent)
                .frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

struct LightfieldTextSegments: View {
    @Environment(\.colorScheme) private var scheme
    let titles: [String]
    @Binding var selection: Int
    let module: ReviewFilter
    var spacing: CGFloat = 26
    var height: CGFloat = 32
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(titles.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Text(titles[index]).font(.system(size: 13, weight: selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? FeatureLightfieldPalette.resolve(scheme).fg : FeatureLightfieldPalette.resolve(scheme).fg2)
                        .lineLimit(1).truncationMode(.tail).frame(height: height)
                        .overlay(alignment: .bottom) {
                            if selection == index { Rectangle().fill(FeatureLightfieldPalette.accent(module)).frame(height: 2) }
                        }
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(titles[index])
                .accessibilityValue(selection == index ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
            }
        }
    }
}

/// The adjacent note uses the primary number's first baseline and stays close
/// (12 pt), as the approved startup summary. Secondary metrics sit at the
/// trailing edge (34 pt apart): 13 pt label over a 24 pt value, as the
/// approved energy/memory summaries.
struct LightfieldSummary: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    let module: ReviewFilter
    let label: String
    let value: String
    let unit: String
    var secondary: [LightfieldMetric] = []
    var note: String? = nil
    /// The page already places its matched artwork at the D67 anchor.
    var artwork: GeneratedArt? = nil
    var showsArtwork = true
    var probeID = "lightfield.summary"
    var primaryCaption = ""
    var valuePrefix = ""
    var secondaryColumnWidth: CGFloat? = nil
    var primaryStatus: FeatureLightfieldStatus? = nil
    var body: some View {
        if compactResults {
            Color.clear.frame(height: 0)
                .preference(key: FeatureLightfieldResultSummaryKey.self, value: FeatureLightfieldResultSummary(
                    primary: .init(id: "primary", label: label, value: value, unit: unit,
                        status: primaryStatus, caption: primaryCaption, valuePrefix: valuePrefix),
                    secondary: secondary, note: note, probeID: probeID))
                .accessibilityHidden(true)
        } else {
            regularSummary
        }
    }
    private var regularSummary: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        return HStack(alignment: showsArtwork ? .center : .top, spacing: FeatureLightfield.summaryGap) {
            Group {
                if showsArtwork {
                    FeatureLightfieldArtwork(art: artwork ?? GeneratedArt.module(for: module), variant: .header)
                } else { Color.clear }
            }
                .frame(width: FeatureLightfield.summaryHeight, height: FeatureLightfield.summaryHeight)
                .lightfieldComponentProbe(probeID + ".art")
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    (Text(valuePrefix).font(.system(size: 15)).foregroundColor(palette.fg2)
                        + Text(value).font(.system(size: primaryCaption.isEmpty ? 52 : 46, weight: .bold)).foregroundColor(primaryStatus?.color(palette) ?? palette.fg)
                        + Text(" " + unit).font(.system(size: 24, weight: .semibold)).foregroundColor(FeatureLightfieldPalette.accent(module)))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: summary-primary
                        .lightfieldComponentProbe(probeID + ".primary")
                    if let note {
                        Text(note).font(.system(size: 15)).foregroundStyle(palette.fg2)
                            .lineLimit(1).truncationMode(.tail).lightfieldComponentProbe(probeID + ".note")
                    }
                }
                if !primaryCaption.isEmpty {
                    Text(primaryCaption).font(.system(size: 11)).foregroundStyle(palette.fg2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .lightfieldComponentProbe(probeID + ".caption")
                }
            }.frame(maxWidth: secondaryColumnWidth != nil ? .infinity : nil, alignment: .leading).layoutPriority(1)
            if secondaryColumnWidth == nil { Spacer(minLength: 0) }
            if !secondary.isEmpty {
                Group {
                    if secondaryColumnWidth == nil {
                        HStack(alignment: .top, spacing: 34) { secondaryMetrics }
                    } else {
                        HStack(alignment: .top, spacing: secondaryColumnWidth == nil ? 34 : 24) { secondaryMetrics }
                    }
                }.padding(.trailing, 6)
            }
        }.frame(height: FeatureLightfield.summaryHeight).foregroundStyle(palette.fg)
        .accessibilityElement(children: .combine).lightfieldComponentProbe(probeID)
    }
    private var secondaryMetrics: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        return ForEach(secondary) { metric in
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.label).font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1)
                (Text(metric.valuePrefix).font(.system(size: 15)).foregroundColor(palette.fg2)
                    + Text(metric.value).font(.system(size: primaryCaption.isEmpty ? 24 : 28, weight: .semibold)).foregroundColor(metric.status?.color(palette) ?? palette.fg)
                    + Text(metric.unit.isEmpty ? "" : " " + metric.unit).font(.system(size: 15))
                        .foregroundColor(palette.fg2))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: summary-secondary
                    .lightfieldComponentProbe(probeID + ".secondary.value." + metric.id)
                if !metric.caption.isEmpty {
                    Text(metric.caption).font(.system(size: 11)).foregroundStyle(palette.fg2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(width: secondaryColumnWidth, alignment: .leading)
            .lightfieldComponentProbe(probeID + ".secondary." + metric.id)
        }
    }
}

extension View {
    /// No geometry reader/probe exists in Release or Beta production bodies.
    func lightfieldComponentProbe(_ id: String) -> some View {
        self
#if DEBUG
            .layoutProbe(id)
#endif
    }
}

/// A B2 summary and its bounded list use the same short-window policy as the
/// original Results component. No page creates a second scrolling skeleton.
struct LightfieldResultContent<Summary: View, Rows: View>: View {
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    var shortSummaryOverlay: AnyView? = nil
    var rowsHaveBlankTopBand = false
    var usesLazyRows = true
    var listHeader: AnyView? = nil
    var listFooter: AnyView? = nil
    @ViewBuilder let summary: Summary
    @ViewBuilder let rows: Rows
    var body: some View {
        GeometryReader { proxy in
            if compactResults {
                FeatureOptionsScrollView(probePrefix: "lightfield.results", balancesContent: false,
                    usesLightfield: true, fadesResults: true, preservesLazyLayout: true) { list }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // The zero-height summary publishes data, never an overlay
                    // or a hidden duplicate of the old result header.
                    .background(alignment: .top) { summary }
            } else if proxy.size.height < 110 {
                FeatureOptionsScrollView(probePrefix: "lightfield.results", balancesContent: false,
                    usesLightfield: true, fadesResults: true) {
                    VStack(spacing: 20) {
                        if let shortSummaryOverlay { summary.overlay(alignment: .leading) { shortSummaryOverlay } }
                        else { summary }
                        list
                    }
                }
            } else {
                VStack(spacing: 20) {
                    summary
                    FeatureOptionsScrollView(probePrefix: "lightfield.results", balancesContent: false,
                        usesLightfield: true, fadesResults: true, snapsResultRows: true,
                        allowsPartialResultRows: rowsHaveBlankTopBand) { list }
                }
            }
        }
    }
    private var list: some View {
        VStack(spacing: 0) {
            if let listHeader { listHeader }
            // Headers/footers must not bias LazyVStack's estimate for the
            // unseen stable rows (especially in a short result viewport).
            if usesLazyRows { LazyVStack(spacing: 0) { rows } }
            else { rows }
            if let listFooter { listFooter }
        }.lightfieldComponentProbe("lightfield.listDocument")
    }
}

private struct LightfieldResultRowBoundary: ViewModifier {
    @Environment(\.featureLightfieldReportsRowTops) private var reportsRowTops
    let isEnabled: Bool
    func body(content: Content) -> some View {
        content.background {
            if reportsRowTops && isEnabled {
                GeometryReader { row in
                    Color.clear.preference(key: FeatureLightfieldRowTopKey.self,
                        value: [row.frame(in: .named(FeatureLightfield.resultsDocumentSpace)).minY])
                }
            }
        }
    }
}
extension View {
    func lightfieldResultRowBoundary(isEnabled: Bool = true) -> some View {
        modifier(LightfieldResultRowBoundary(isEnabled: isEnabled))
    }
}
