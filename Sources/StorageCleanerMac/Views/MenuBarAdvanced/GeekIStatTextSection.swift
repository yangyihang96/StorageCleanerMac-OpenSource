import AppKit
import SwiftUI

/// D124: iStat Menus 7.30's text section (`BBRMenuTextSection`) as its
/// selectable submenus draw it: the energy-mode menu
/// (`-[BatteryMenu updateEnergyModeDisplay]`) and the section's
/// `drawRect:` / `intrinsicContentSize`. In points inside a card:
/// - the first row 5 from the top, 5 below the last;
/// - a major label (upper case, the section-title style) or a label row is
///   its 15 pt text box and a 2 pt gap; a tick row is 15 with no gap; a
///   toggle row 18;
/// - a tick row's label is at 8 in W − 30; the selected row's check is a
///   2 pt line (W − 16, 8) → (W − 13, 11) → (W − 9, 3) in the value color;
/// - a major label with a dot: an 8 pt dot at (W − 16, 3) in the label's
///   color, the label in W − 24;
/// - a toggle: a 26 × 14 track (radius 8) at W − 34 and a 14 pt knob;
/// - a selectable row's hover region spans the card at the row's 15 pt
///   (`highlightConfig`: itemOffset 22, itemHeight 15, no spacing), drawn as
///   the 1 pt accent line on the region inset by 1 at radius 6;
/// - the width: the widest row + 16, at least 150 (`setMinimumWidth: 150`).
enum GeekIStatTextSectionGeometry {
    static let top: CGFloat = 5
    static let bottom: CGFloat = 5
    static let rowHeight: CGFloat = 15
    static let labelRowGap: CGFloat = 2
    static let toggleRowHeight: CGFloat = 18
    static let leading: CGFloat = 8
    static let tickLabelTrailing: CGFloat = 30
    static let dotLabelTrailing: CGFloat = 24
    static let dotSize: CGFloat = 8
    static let dotTop: CGFloat = 3
    /// The check's points as (distance from the row's trailing edge, y).
    static let checkPoints: [(trailing: CGFloat, y: CGFloat)] = [(16, 8), (13, 11), (9, 3)]
    static let checkLineWidth: CGFloat = 2
    static let toggleTrackSize = CGSize(width: 26, height: 14)
    static let toggleTrackRadius: CGFloat = 8
    static let toggleKnobSize: CGFloat = 14
    /// The track's leading edge from the section's trailing edge.
    static let toggleTrailing: CGFloat = 34
    static let minimumWidth: CGFloat = 150
    static let widthPadding: CGFloat = 16
    /// The first selectable row under a major label: 5 + 15 + 2.
    static var itemOffset: CGFloat { top + rowHeight + labelRowGap }

    /// A section of `labelRows` major-label or label rows and `tickRows` tick
    /// rows: an energy-mode section with three modes is 72.
    static func height(labelRows: Int, tickRows: Int, toggleRows: Int = 0) -> CGFloat {
        top
            + CGFloat(max(0, labelRows)) * (rowHeight + labelRowGap)
            + CGFloat(max(0, tickRows)) * rowHeight
            + CGFloat(max(0, toggleRows)) * toggleRowHeight
            + bottom
    }
}

/// D137: iStat Menus 7.30's content widths, so a content-sized submenu is
/// as wide as its widest section. A text section
/// (`-[BBRMenuTextSection intrinsicContentSize]`) is its widest row + 16,
/// from 200 (150 where the menu sets it) to 350; a label-and-value row is
/// ceil(label) + ceil(value) + 30, a row of one label, value or major label
/// its text; the section's own label is not measured. A button
/// (`-[BBRButtonMenuItem intrinsicContentSize]`) is its label + 20, from
/// 200 to 350. The submenu (`setWidth:` in `updateInterfaceSubmenu`,
/// `updateBatterySubmenu` and `updateUptimeSubmenu`) is its widest
/// section, truncated, + 20: a card is 4 wider than that section between
/// the page's 8 pt insets. Text is measured in the rows' 12 pt font; iStat
/// measures a major label alone in the label font too.
enum GeekIStatContentWidth {
    static let sectionMinimum: CGFloat = 200
    static let sectionMaximum: CGFloat = 350
    static let rowPadding: CGFloat = 30
    static let buttonPadding: CGFloat = 20
    static let pagePadding: CGFloat = 20

    static func text(_ string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont.monospacedDigitSystemFont(ofSize: GeekIStatCardGeometry.textFontSize, weight: .regular)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    static func row(title: String, value: String) -> CGFloat {
        text(title) + text(value) + rowPadding
    }

    static func section(rows: [CGFloat], minimum: CGFloat = sectionMinimum) -> CGFloat {
        min(sectionMaximum, max(minimum, (rows.max() ?? 0) + GeekIStatTextSectionGeometry.widthPadding))
    }

    static func button(title: String) -> CGFloat {
        min(sectionMaximum, max(sectionMinimum, (text(title) + buttonPadding).rounded(.down)))
    }

    static func page(sections: [CGFloat]) -> CGFloat {
        (sections.max() ?? sectionMinimum).rounded(.down) + pagePadding
    }
}

/// A text section card: the rows on the card surface between the 5 pt
/// insets. Rows span the card's width and carry their own 8 pt insets, so a
/// selectable row's highlight can reach the card's edges as on iStat.
struct GeekIStatTextSectionCard<Rows: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    let rows: Rows

    init(@ViewBuilder rows: () -> Rows) {
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { rows }
            .padding(.top, GeekIStatTextSectionGeometry.top)
            .padding(.bottom, GeekIStatTextSectionGeometry.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .geekCardSurface(colorScheme: colorScheme, visualMode: visualMode,
                             displayScale: displayScale, palette: panelChromePalette)
    }
}

/// A major label row: the title in the section-title style, an optional
/// 8 pt dot in the same color at (W − 16, 3) (the energy-mode menu marks the
/// current power source with it), and a trailing accessory (a warning, a
/// toggle) in the same place. The section draws its label as given: the
/// energy-mode menu passes upper case, the interface submenu (D125) passes
/// "Interface", "Wi-Fi", "IPv4" as they are and only "IP Addresses" in upper
/// case. A label alone in its section is 25 tall: no gap below it.
struct GeekIStatMajorLabelRow<Accessory: View>: View {
    @Environment(\.panelMetricColors) private var metricColors
    let title: String
    let showsDot: Bool
    let isUppercased: Bool
    let hasRowsBelow: Bool
    /// D140: where the label ends from the section's trailing edge when the
    /// section draws something there (the public IP section's flag: 42);
    /// nil for the dot's or the 8 pt inset.
    let trailingInset: CGFloat?
    let accessory: Accessory

    init(
        title: String,
        showsDot: Bool = false,
        isUppercased: Bool = true,
        hasRowsBelow: Bool = true,
        trailingInset: CGFloat? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.showsDot = showsDot
        self.isUppercased = isUppercased
        self.hasRowsBelow = hasRowsBelow
        self.trailingInset = trailingInset
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(title)
                .font(AdvancedPanelTypography.header)
                .textCase(isUppercased ? .uppercase : nil)
                .foregroundStyle(metricColors.sectionHeader)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            accessory
        }
        .frame(height: GeekIStatTextSectionGeometry.rowHeight)
        .padding(.leading, GeekIStatTextSectionGeometry.leading)
        .padding(.trailing, trailingInset
            ?? (showsDot ? GeekIStatTextSectionGeometry.dotLabelTrailing : GeekIStatTextSectionGeometry.leading))
        .overlay(alignment: .topTrailing) {
            if showsDot {
                Circle()
                    .fill(metricColors.sectionHeader)
                    .frame(width: GeekIStatTextSectionGeometry.dotSize, height: GeekIStatTextSectionGeometry.dotSize)
                    .padding(.top, GeekIStatTextSectionGeometry.dotTop)
                    .padding(.trailing, GeekIStatTextSectionGeometry.leading)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, hasRowsBelow ? GeekIStatTextSectionGeometry.labelRowGap : 0)
    }
}

extension GeekIStatMajorLabelRow where Accessory == EmptyView {
    init(title: String, showsDot: Bool = false, isUppercased: Bool = true, hasRowsBelow: Bool = true,
         trailingInset: CGFloat? = nil) {
        self.init(title: title, showsDot: showsDot, isUppercased: isUppercased, hasRowsBelow: hasRowsBelow,
                  trailingInset: trailingInset) {
            EmptyView()
        }
    }
}

/// A selectable 15 pt row: the label at 8 in W − 30 in the label color, the
/// check of the selected row in the value color, and the hover highlight on
/// the row's region across the card. Without `showsCheck` it is an action
/// row of ours (open the battery settings, charge to full) in the same form.
/// The app's button family dims a disabled row and darkens a pressed one.
struct GeekIStatTickRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let isSelected: Bool
    var showsCheck = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .geekIStatLabelText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, GeekIStatTextSectionGeometry.leading)
                .padding(.trailing, GeekIStatTextSectionGeometry.tickLabelTrailing)
                .frame(height: GeekIStatTextSectionGeometry.rowHeight)
                .overlay {
                    if showsCheck && isSelected {
                        GeekIStatCheckmark()
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .overlay {
            if isHovered && isEnabled {
                GeekCardHighlight(
                    color: panelChromePalette?.accent ?? GeekVisualTokens.cardBorder(
                        for: colorScheme, visualMode: visualMode, isSelected: true
                    ),
                    cornerRadius: GeekVisualTokens.highlightRadius(rowHeight: GeekIStatTextSectionGeometry.rowHeight)
                )
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(showsCheck
            ? (isSelected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not Selected"))
            : "")
        .accessibilityAddTraits(showsCheck && isSelected ? [.isSelected] : [])
    }
}

/// The tick of a selected row, drawn across the row's full width.
struct GeekIStatCheckmark: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for (index, point) in GeekIStatTextSectionGeometry.checkPoints.enumerated() {
                    let location = CGPoint(x: proxy.size.width - point.trailing, y: point.y)
                    if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                }
            }
            .stroke(Color.primary, lineWidth: GeekIStatTextSectionGeometry.checkLineWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The text section's toggle (`-[BBRMenuToggle drawRect:]`): a 26 × 14
/// track at radius 8 and a 14 pt knob, trailing while on. D135: the track
/// takes the control color while on and the theme's graph border color
/// while off; the knob takes the label color.
struct GeekIStatSwitch: View {
    @Environment(\.panelChromePalette) private var panelChromePalette
    let isOn: Bool

    private var trackColor: Color {
        if isOn {
            return panelChromePalette?.accentColors?.control ?? panelChromePalette?.accent ?? AppAppearanceColors.controlAccent
        }
        return panelChromePalette?.graphBorder ?? Color.primary.opacity(0.2)
    }

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: GeekIStatTextSectionGeometry.toggleTrackRadius, style: .circular)
                .fill(trackColor)
            Circle()
                .fill(GeekIStatCardGeometry.labelColor(panelChromePalette))
                .frame(width: GeekIStatTextSectionGeometry.toggleKnobSize, height: GeekIStatTextSectionGeometry.toggleKnobSize)
        }
        .frame(width: GeekIStatTextSectionGeometry.toggleTrackSize.width,
               height: GeekIStatTextSectionGeometry.toggleTrackSize.height)
        .accessibilityHidden(true)
    }
}

/// A toggle drawn as the text section's switch, keeping the native toggle's
/// accessibility (its label, state and press action).
struct GeekIStatSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                configuration.label
                GeekIStatSwitch(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? L10n.text("开", "On") : L10n.text("关", "Off"))
    }
}

extension View {
    /// A note of ours in a text section (what a state means, why an action
    /// is unavailable): the caption wrapping inside the 8 pt insets, as a
    /// label row with its 2 pt gap. iStat's sections carry no notes.
    func geekIStatSectionNote(_ color: Color? = nil) -> some View {
        font(AdvancedPanelTypography.caption)
            .foregroundStyle(color ?? AppDesignTokens.Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GeekIStatTextSectionGeometry.leading)
            .padding(.bottom, GeekIStatTextSectionGeometry.labelRowGap)
    }
}
