import AppKit
import SwiftUI

/// D125: iStat Menus 7.30's interface submenu (`-[NetworkMenu
/// updateInterfaceSubmenu]`, `loadItems`), which is its VPN submenu too: a
/// VPN is an interface there, drawn with a lock in the menu
/// (`BBRNetworkMenuInterfaceSection`). The sections, in order and each only
/// with something to show: the interface (BSD name, MAC address, link
/// speed), the media options, Wi-Fi with its power switch, the addresses,
/// IPv4 (subnet masks, router, DNS), IPv6 (router, DNS), then the DHCP and
/// disconnect buttons. In points:
/// - a text section (`BBRMenuTextSection`): its label at (8, 5) as given (the
///   addresses' label alone is upper case), rows from 22 on the 17 pt pitch
///   and 5 below the last, 27 + 17n; a label alone is 25;
/// - the addresses (`BBRNetworkMenuIPSection`, `GeekIStatIPSection`): one
///   left-aligned row per address from 22 and 5 below, 27 + 15n; D140: an
///   address too long for the section wraps, 15 a line (was truncated in
///   the middle);
/// - a button (`BBRButtonMenuItem`): the section's width and 31 tall, its
///   label centered in (10, 7, W − 20);
/// - the Wi-Fi switch (`BBRMenuToggle`): 26 × 14, 8 from the right, at 6;
/// - IPv4, IPv6 and address rows are selectable: the row's 15 pt region
///   highlights across the section, and a click copies the value and closes
///   the menu (`onSelect`, `-[BBRNetworkMenuIPSection mouseDown:]`).
enum GeekIStatInterfaceGeometry {
    static let rowsTop: CGFloat = 22
    static let bottom: CGFloat = 5
    static let labelOnlyHeight: CGFloat = 25
    static let addressRowHeight: CGFloat = 15
    static let buttonHeight: CGFloat = 31
    static let buttonLabelInset: CGFloat = 10
    static let buttonLabelTop: CGFloat = 7
    static let destructiveInset: CGFloat = 2
    static let destructiveCornerRadius: CGFloat = 6
    /// The disconnect button's gradient (type 2) from the top to the bottom:
    /// iStat draws (1, 0.082, 0.086) → (1, 0.242, 0.246) at −90° in its
    /// flipped view.
    static let destructiveTop = Color(nsColor: NSColor(red: 1, green: 0.242, blue: 0.246, alpha: 1))
    static let destructiveBottom = Color(nsColor: NSColor(red: 1, green: 0.082, blue: 0.086, alpha: 1))

    static func textSectionHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return labelOnlyHeight }
        return rowsTop + GeekIStatSectionGeometry.rowPitch * CGFloat(rows) + bottom
    }

    /// `addresses` addresses of one line each.
    static func addressSectionHeight(addresses: Int) -> CGFloat {
        rowsTop + addressRowHeight * CGFloat(max(0, addresses)) + bottom
    }

    /// D140: the IP section's own measure (`-[BBRNetworkMenuIPSection
    /// intrinsicContentSize]`): from 22, each address's height in the rows'
    /// font wrapping at `textWidth` (the section's W − 16), the sum truncated
    /// after each, then 5 below; 27 with no address. A line is 15.
    static func addressSectionHeight(addresses: [String], textWidth: CGFloat) -> CGFloat {
        var bottomEdge = rowsTop
        for address in addresses {
            bottomEdge = (bottomEdge + addressHeight(address, textWidth: textWidth)).rounded(.towardZero)
        }
        return bottomEdge + bottom
    }

    /// iStat's `boundingRectWithSize:(W − 16, ∞) options:0x21` (line-fragment
    /// origin, last visible line truncated) in the value font.
    static func addressHeight(_ address: String, textWidth: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: GeekIStatCardGeometry.textFontSize, weight: .regular)
        return (address as NSString).boundingRect(
            with: NSSize(width: max(1, textWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font]
        ).height
    }

    /// An address's width in a section `sectionWidth` wide: 8 on each side.
    static func addressTextWidth(sectionWidth: CGFloat) -> CGFloat {
        sectionWidth - 2 * GeekIStatTextSectionGeometry.leading
    }

    /// A submenu page's section: the page less its 8 pt insets.
    static func sectionWidth(pageWidth: CGFloat) -> CGFloat {
        pageWidth - 2 * GeekPanelLayout.contentPadding
    }
}

/// D125: one interface's submenu in iStat's formats, built once so the page
/// and its size agree. The network page builds it from the physical
/// connection or a VPN tunnel, with iStat's labels
/// (`GeekNetworkView.swift`).
struct GeekIStatInterfaceModel: Equatable {
    struct Row: Equatable {
        let title: String
        let value: String
    }

    var bsdName: String?
    var hardwareAddress: String?
    var linkSpeed: String?
    var mediaOptions: [String] = []
    /// The Wi-Fi section's rows; nil when the interface has no Wi-Fi section.
    var wiFiRows: [Row]?
    var addresses: [String] = []
    var ipv4Rows: [Row] = []
    var ipv6Rows: [Row] = []

    var interfaceRowCount: Int {
        [bsdName, hardwareAddress, linkSpeed].compactMap { $0 }.count
    }

    /// The sections' heights in their order on the page of `pageWidth()`;
    /// the interface section is always there.
    var sectionHeights: [CGFloat] {
        sectionHeights(pageWidth: pageWidth())
    }

    /// The sections' heights on a page `pageWidth` wide. D140: an address
    /// that wraps in its section adds its lines (was 15 an address).
    func sectionHeights(pageWidth: CGFloat) -> [CGFloat] {
        typealias Geometry = GeekIStatInterfaceGeometry
        var heights = [Geometry.textSectionHeight(rows: interfaceRowCount)]
        if !mediaOptions.isEmpty {
            heights.append(Geometry.textSectionHeight(rows: mediaOptions.count))
        }
        if let wiFiRows {
            heights.append(Geometry.textSectionHeight(rows: wiFiRows.count))
        }
        if !addresses.isEmpty {
            heights.append(Geometry.addressSectionHeight(
                addresses: addresses,
                textWidth: Geometry.addressTextWidth(sectionWidth: Geometry.sectionWidth(pageWidth: pageWidth))
            ))
        }
        for rows in [ipv4Rows, ipv6Rows] where !rows.isEmpty {
            heights.append(GeekIStatInterfaceGeometry.textSectionHeight(rows: rows.count))
        }
        return heights
    }

    /// D137: the page's width, iStat's for the submenu
    /// (`GeekIStatContentWidth`): the widest of the interface, media options,
    /// Wi-Fi, IPv4 and IPv6 sections and the buttons below them, + 20. The
    /// addresses take the menu's width and do not widen it
    /// (`BBRNetworkMenuIPSection`). The MAC address counts the wider of its
    /// masked and full forms, so showing it never resizes the page.
    func pageWidth(buttonTitles: [String] = []) -> CGFloat {
        typealias Width = GeekIStatContentWidth
        func section(_ rows: [Row]) -> CGFloat {
            Width.section(rows: rows.map { Width.row(title: $0.title, value: $0.value) })
        }
        var interfaceRows: [CGFloat] = []
        if let bsdName {
            interfaceRows.append(Width.row(title: Self.bsdNameTitle, value: bsdName))
        }
        if let hardwareAddress {
            interfaceRows.append([false, true].map { isRevealed in
                Width.row(title: Self.hardwareAddressTitle,
                          value: GeekIStatHardwareAddressRow.displayed(hardwareAddress, isRevealed: isRevealed))
            }.max() ?? 0)
        }
        if let linkSpeed {
            interfaceRows.append(Width.row(title: Self.linkSpeedTitle, value: linkSpeed))
        }
        var sections = [Width.section(rows: interfaceRows)]
        if !mediaOptions.isEmpty {
            sections.append(Width.section(rows: mediaOptions.map(Width.text)))
        }
        if let wiFiRows {
            sections.append(section(wiFiRows))
        }
        for rows in [ipv4Rows, ipv6Rows] where !rows.isEmpty {
            sections.append(section(rows))
        }
        return Width.page(sections: sections + buttonTitles.map(Width.button))
    }
}

/// What a selectable row does: iStat copies the row's value and closes the
/// whole menu (`-[NSPasteboard setString:forType:]`, then `rootMenu close`).
/// Tests inject their own, so a layout check never touches the pasteboard.
struct GeekIStatCopyAction: Sendable {
    let perform: @MainActor @Sendable (String) -> Void

    static let copyAndClosePanel = GeekIStatCopyAction { value in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        MenuBarStatusController.shared.dismissPanel()
    }
}

private struct GeekIStatCopyActionKey: EnvironmentKey {
    static let defaultValue = GeekIStatCopyAction.copyAndClosePanel
}

extension EnvironmentValues {
    var geekIStatCopyAction: GeekIStatCopyAction {
        get { self[GeekIStatCopyActionKey.self] }
        set { self[GeekIStatCopyActionKey.self] = newValue }
    }
}

/// D125: the interface submenu's sections for `model`, for a caller's stack
/// 7 pt apart. The Wi-Fi switch is the caller's; so is the MAC address's
/// reveal (ours: the address stays masked until it is shown).
struct GeekIStatInterfaceSections<WiFiAccessory: View>: View {
    let model: GeekIStatInterfaceModel
    @Binding var revealsHardwareAddress: Bool
    let wiFiAccessory: WiFiAccessory

    init(
        model: GeekIStatInterfaceModel,
        revealsHardwareAddress: Binding<Bool> = .constant(false),
        @ViewBuilder wiFiAccessory: () -> WiFiAccessory
    ) {
        self.model = model
        _revealsHardwareAddress = revealsHardwareAddress
        self.wiFiAccessory = wiFiAccessory()
    }

    var body: some View {
        GeekIStatTextSectionCard {
            GeekIStatMajorLabelRow(
                title: GeekIStatInterfaceModel.interfaceTitle,
                isUppercased: false,
                hasRowsBelow: model.interfaceRowCount > 0
            )
            if let bsdName = model.bsdName {
                GeekIStatValueRow(title: GeekIStatInterfaceModel.bsdNameTitle, value: bsdName)
            }
            if let hardwareAddress = model.hardwareAddress {
                GeekIStatHardwareAddressRow(address: hardwareAddress, isRevealed: $revealsHardwareAddress)
            }
            if let linkSpeed = model.linkSpeed {
                GeekIStatValueRow(title: GeekIStatInterfaceModel.linkSpeedTitle, value: linkSpeed)
            }
        }

        if !model.mediaOptions.isEmpty {
            GeekIStatTextSectionCard {
                GeekIStatMajorLabelRow(title: GeekIStatInterfaceModel.mediaOptionsTitle, isUppercased: false)
                ForEach(Array(model.mediaOptions.enumerated()), id: \.offset) { _, option in
                    Text(option)
                        .geekIStatLabelText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: GeekIStatSectionGeometry.rowHeight)
                        .padding(.horizontal, GeekIStatTextSectionGeometry.leading)
                        .padding(.bottom, GeekIStatTextSectionGeometry.labelRowGap)
                }
            }
        }

        if let wiFiRows = model.wiFiRows {
            GeekIStatTextSectionCard {
                GeekIStatMajorLabelRow(title: "Wi-Fi", isUppercased: false, hasRowsBelow: !wiFiRows.isEmpty) {
                    wiFiAccessory
                }
                ForEach(Array(wiFiRows.enumerated()), id: \.offset) { _, row in
                    GeekIStatValueRow(title: row.title, value: row.value)
                }
            }
        }

        if !model.addresses.isEmpty {
            GeekIStatIPSection(title: GeekIStatInterfaceModel.addressesTitle, addresses: model.addresses)
        }

        if !model.ipv4Rows.isEmpty {
            addressFamilySection(title: "IPv4", rows: model.ipv4Rows)
        }
        if !model.ipv6Rows.isEmpty {
            addressFamilySection(title: "IPv6", rows: model.ipv6Rows)
        }
    }

    private func addressFamilySection(title: String, rows: [GeekIStatInterfaceModel.Row]) -> some View {
        GeekIStatTextSectionCard {
            GeekIStatMajorLabelRow(title: title, isUppercased: false)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GeekIStatSelectableRow(value: row.value, accessibilityLabel: "\(row.title), \(row.value)") {
                    GeekIStatValueRowContent(title: row.title, value: row.value)
                }
                .padding(.bottom, GeekIStatTextSectionGeometry.labelRowGap)
            }
        }
    }
}

/// D140: the IP section's own items (`-[BBRNetworkMenuIPSection drawRect:]`
/// and `mouseDown:`), from the section's top and trailing edges.
enum GeekIStatIPSectionGeometry {
    /// The flag: an 18 pt emoji drawn in (W − 30, 2, 20, 20).
    static let flagFontSize: CGFloat = 18
    static let flagSize: CGFloat = 20
    static let flagTop: CGFloat = 2
    static let flagTrailing: CGFloat = 10
    /// The refresh icon in (W − 24, 4, 16, 16), or (W − 50, 4, 16, 16)
    /// beside a flag; its rect is the click's too.
    static let refreshSize: CGFloat = 16
    static let refreshTop: CGFloat = 4
    static let refreshTrailing: CGFloat = 8
    static let refreshTrailingBesideFlag: CGFloat = 34
    /// Ours: the symbol inside the 16 pt rect.
    static let refreshGlyphSize: CGFloat = 12
    /// Beside a flag the label is W − 50 wide from 8, so it ends 42 from
    /// the trailing edge.
    static let flagLabelTrailing: CGFloat = 42

    /// The network menu's sections: the 301 pt page less its 8 pt insets.
    static var networkPageSectionWidth: CGFloat {
        GeekIStatInterfaceGeometry.sectionWidth(pageWidth: GeekPanelPresentationMetrics.detailWidth(for: .network))
    }

    /// A section of `addresses` in the network menu.
    static func networkPageHeight(addresses: [String]) -> CGFloat {
        GeekIStatInterfaceGeometry.addressSectionHeight(
            addresses: addresses,
            textWidth: GeekIStatInterfaceGeometry.addressTextWidth(sectionWidth: networkPageSectionWidth)
        )
    }
}

/// D140: iStat Menus 7.30's IP section (`BBRNetworkMenuIPSection`), in the
/// network menu (the public and the local addresses) and in an interface's
/// submenu. The label in upper case at (8, 5) in the section-title style;
/// each address from 22 at 8 in the value font, left-aligned and wrapping at
/// W − 16, 15 a line; 5 below the last, 27 with no address. The public
/// section (`BBRNetworkMenuIPSectionPublic`) draws the country's flag, and
/// while the section is hovered (`highlighted`) its refresh icon
/// (`supportsRefresh`, `onRefresh`), an SF Symbol in the value color (D123:
/// none of iStat's images). A row's region highlights while hovered, and a
/// click copies the address and closes the panel. Without an address the
/// section draws its label only, as iStat; `status` (reading, unavailable)
/// is its help and its VoiceOver value.
struct GeekIStatIPSection: View {
    let title: String
    let addresses: [String]
    var flag: String?
    var refresh: (() -> Void)?
    var status: String?
    @State private var isHovered = false

    var body: some View {
        GeekIStatTextSectionCard {
            GeekIStatMajorLabelRow(
                title: title,
                trailingInset: flag == nil ? nil : GeekIStatIPSectionGeometry.flagLabelTrailing
            )
            ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                GeekIStatSelectableRow(value: address, accessibilityLabel: address) {
                    Text(address)
                        .geekIStatValueText(lineLimit: nil)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if let flag {
                    Text(flag)
                        .font(.system(size: GeekIStatIPSectionGeometry.flagFontSize))
                        .fixedSize()
                        .frame(width: GeekIStatIPSectionGeometry.flagSize,
                               height: GeekIStatIPSectionGeometry.flagSize, alignment: .topLeading)
                        .padding(.top, GeekIStatIPSectionGeometry.flagTop)
                        .padding(.trailing, GeekIStatIPSectionGeometry.flagTrailing)
                        .accessibilityHidden(true)
                }
                if let refresh {
                    // Kept in place while hidden, so VoiceOver can reach it.
                    GeekIStatIPRefreshButton(action: refresh)
                        .padding(.top, GeekIStatIPSectionGeometry.refreshTop)
                        .padding(.trailing, flag == nil
                            ? GeekIStatIPSectionGeometry.refreshTrailing
                            : GeekIStatIPSectionGeometry.refreshTrailingBesideFlag)
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                }
            }
        }
        .onHover { isHovered = $0 }
        .modifier(GeekIStatIPSectionStatus(status: addresses.isEmpty ? status : nil))
    }
}

private struct GeekIStatIPRefreshButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppSymbolGlyph(systemImage: AppSymbols.Action.refresh, size: GeekIStatIPSectionGeometry.refreshGlyphSize)
                .modifier(GeekIStatTextColor(role: .value))
                .frame(width: GeekIStatIPSectionGeometry.refreshSize, height: GeekIStatIPSectionGeometry.refreshSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .help(L10n.text("重新查询公共 IP 地址", "Look up the public IP addresses again"))
        .accessibilityLabel(Text(L10n.text("刷新公共 IP 地址", "Refresh Public IP Addresses")))
    }
}

private struct GeekIStatIPSectionStatus: ViewModifier {
    let status: String?

    func body(content: Content) -> some View {
        if let status {
            content
                .help(status)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(status))
        } else {
            content
        }
    }
}

/// A label and value row's content: the label in the label color, the
/// value right-aligned in the value color; a long value gives way in the
/// middle.
struct GeekIStatValueRowContent: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(title)
                .geekIStatLabelText()
                .fixedSize()
            Spacer(minLength: 0)
            Text(value)
                .geekIStatValueText()
                .truncationMode(.middle)
        }
    }
}

/// A text section's label and value row (`label`/`value`): 15 pt inside
/// the 8 pt insets and the 2 pt gap; the value shows complete in its help.
struct GeekIStatValueRow: View {
    let title: String
    let value: String

    var body: some View {
        GeekIStatValueRowContent(title: title, value: value)
            .help(value)
            .frame(height: GeekIStatSectionGeometry.rowHeight)
            .padding(.horizontal, GeekIStatTextSectionGeometry.leading)
            .padding(.bottom, GeekIStatTextSectionGeometry.labelRowGap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value)")
    }
}

/// The MAC address row. iStat shows the address; ours keeps the first four
/// bytes masked until the value is clicked (a privacy rule since 1.9.10).
struct GeekIStatHardwareAddressRow: View {
    let address: String
    @Binding var isRevealed: Bool

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(GeekIStatInterfaceModel.hardwareAddressTitle)
                .geekIStatLabelText()
                .fixedSize()
            Spacer(minLength: 0)
            Button {
                isRevealed.toggle()
            } label: {
                Text(displayedAddress)
                    .geekIStatValueText()
                    .truncationMode(.middle)
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .help(isRevealed
                ? L10n.text("点按隐藏 MAC 地址", "Click to hide the MAC address")
                : L10n.text("点按显示完整 MAC 地址", "Click to show the full MAC address"))
            .accessibilityLabel(isRevealed
                ? L10n.text("隐藏 MAC 地址", "Hide MAC address")
                : L10n.text("显示 MAC 地址", "Show MAC address"))
            .accessibilityValue(displayedAddress)
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
        .padding(.horizontal, GeekIStatTextSectionGeometry.leading)
        .padding(.bottom, GeekIStatTextSectionGeometry.labelRowGap)
    }

    var displayedAddress: String {
        Self.displayed(address, isRevealed: isRevealed)
    }

    nonisolated static func displayed(_ address: String, isRevealed: Bool) -> String {
        guard !isRevealed else { return address }
        let components = address.split(separator: ":").map(String.init)
        guard components.count >= 2 else { return "••:••:••:••:••:••" }
        return "••:••:••:••:\(components.suffix(2).joined(separator: ":"))"
    }
}

/// A selectable 15 pt row: its region highlights across the section while
/// hovered, and a click copies `value` and closes the panel
/// (`geekIStatCopyAction`).
struct GeekIStatSelectableRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.geekIStatCopyAction) private var copyAction
    let value: String
    let accessibilityLabel: String
    let content: Content
    @State private var isHovered = false

    init(value: String, accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        Button {
            copyAction.perform(value)
        } label: {
            // D140: at least 15; an address that wraps is 15 a line, and its
            // region highlights at its own height (was always 15).
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: GeekIStatSectionGeometry.rowHeight)
                .padding(.horizontal, GeekIStatTextSectionGeometry.leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .overlay {
            if isHovered {
                GeometryReader { proxy in
                    GeekCardHighlight(
                        color: panelChromePalette?.accent ?? GeekVisualTokens.cardBorder(
                            for: colorScheme, visualMode: visualMode, isSelected: true
                        ),
                        cornerRadius: GeekVisualTokens.highlightRadius(rowHeight: proxy.size.height)
                    )
                }
            }
        }
        .onHover { isHovered = $0 }
        .help(L10n.text("点按拷贝 \(value)", "Click to copy \(value)"))
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(L10n.text("拷贝并关闭小窗", "Copies it and closes the panel")))
    }
}

/// iStat's button item (`BBRButtonMenuItem`): the section's width and 31
/// tall on the card's fill and border, the accent line inside it while
/// hovered, the label centered at 7. The destructive kind (type 2, the
/// disconnect button) fills a red gradient inset by 2 at radius 6 and
/// draws its label in white. The app's button family dims a disabled button
/// and darkens a pressed one.
struct GeekIStatButtonItem: View {
    enum Kind: Equatable {
        case standard
        case destructive
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let kind: Kind
    var isBusy = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: GeekIStatCardGeometry.textFontSize))
                    // iStat: type 0 in the theme's value color, type 2 white.
                    .foregroundStyle(kind == .destructive ? Color.white : GeekIStatCardGeometry.valueColor(panelChromePalette))
                    .lineLimit(1)
            }
            .frame(height: GeekIStatSectionGeometry.rowHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, GeekIStatInterfaceGeometry.buttonLabelInset)
            .padding(.top, GeekIStatInterfaceGeometry.buttonLabelTop)
            .frame(height: GeekIStatInterfaceGeometry.buttonHeight, alignment: .top)
            .background {
                if kind == .destructive {
                    RoundedRectangle(cornerRadius: GeekIStatInterfaceGeometry.destructiveCornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [GeekIStatInterfaceGeometry.destructiveTop, GeekIStatInterfaceGeometry.destructiveBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .padding(GeekIStatInterfaceGeometry.destructiveInset)
                }
            }
            .geekCardSurface(colorScheme: colorScheme, visualMode: visualMode,
                             displayScale: displayScale, palette: panelChromePalette)
            .overlay {
                if isHovered && isEnabled {
                    GeekCardHighlight(color: panelChromePalette?.accent ?? GeekVisualTokens.cardBorder(
                        for: colorScheme, visualMode: visualMode, isSelected: true
                    ))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: GeekVisualTokens.cardRadius, style: .continuous))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(isBusy ? Text(L10n.text("正在处理", "In progress")) : Text(""))
    }
}
