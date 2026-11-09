import SwiftUI

/// D272: every page starts at the same place, so the title stays put when the
/// tab changes, and the page's height goes to its content (was B6's frozen
/// geometry: the title at 52/12 on the pages with a preview and 96/92 on the
/// others, with 108 pt kept for a footer repeating one sentence). The preview
/// owns its natural height; only its viewport scrolls.
/// D210: a page with a minimum content height (the ignore list) keeps it in a
/// shorter window and the whole page scrolls (`documentHeight` past the
/// viewport). Other pages are unchanged.
struct SettingsLightfieldGeometry: Equatable {
    let title: CGRect
    let content: CGRect
    /// The page's height: the viewport's, unless the page scrolls.
    let documentHeight: CGFloat

    init(size: CGSize, category: SettingsCategory) {
        let inset: CGFloat = size.width >= 760 ? 52 : 24
        let width = max(0, size.width - inset - 24)
        title = CGRect(x: inset, y: 12, width: width, height: 48)
        let contentY: CGFloat = 72
        content = CGRect(x: inset, y: contentY, width: width,
                         height: max(max(0, size.height - contentY), category.minimumContentHeight))
        documentHeight = max(size.height, content.maxY)
    }
}

extension SettingsCategory {
    /// D154 batch 3J: each tab's own picture, as CleanMyMac's settings tabs
    /// have (they borrowed module pictures: radar, chip, broom, globe, heart,
    /// file analysis); About shows the app's own icon. D166② drew the four
    /// new ones in their final colours (this window turns no picture).
    var tabArt: GeneratedArt? {
        switch self {
        case .general: .tileGeneral
        case .miniWindow: .tileMiniWindow
        case .scanAndSafety: .tileScanSafety
        case .accessAndSetup: .statePermission
        // D273: reuses the sparkle of the AI clutter tile, as Updates reuses the
        // updater's picture.
        case .aiAssistant: .tileAIClutter
        case .systemControl: .tileSystemControl
        case .updates: .updater
        // D207 补: the ignore list reuses the no-entry picture, as Updates
        // reuses the updater's; the tabs show pictures, never SF Symbols.
        case .ignoreList: .tileSensitive
        case .about: nil
        }
    }

    /// D210: the least height a page's content lays out at. The ignore
    /// list asks for room for every category (or three whole entries); a
    /// shorter window scrolls the whole page instead of squeezing it.
    var minimumContentHeight: CGFloat {
        self == .ignoreList ? SettingsIgnoreListMetrics.minimumHeight : 0
    }

    /// D273: a tab is wide enough for its whole title on two lines, broken at
    /// the best space, so a narrow window never cuts a word (was `minWidth: 64`
    /// for every tab: nine need 616 pt, and any one width that fits the window
    /// breaks "Reminders" inside the word). Measured in the selected weight, so
    /// selecting a tab moves nothing.
    var minimumTabWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: SettingsTabBar.titleSize, weight: .semibold)
        func width(_ words: ArraySlice<Substring>) -> CGFloat {
            ceil((words.joined(separator: " ") as NSString).size(withAttributes: [.font: font]).width)
        }
        let words = title.split(separator: " ")
        let narrowest = words.indices.dropFirst().map { max(width(words[..<$0]), width(words[$0...])) }.min() ?? width(words[...])
        return narrowest + 2 * SettingsTabBar.tabPadding
    }
}

struct SettingsLightfieldPane<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let category: SettingsCategory
    /// D154 batch 3I: the window draws one backdrop behind its tabs and the
    /// pane, so the pane leaves its own out there.
    var drawsBackdrop = true
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { viewport in
            let geometry = SettingsLightfieldGeometry(size: viewport.size, category: category)
            let palette = FeatureLightfieldPalette.resolve(scheme)
            let page = ZStack(alignment: .topLeading) {
                HStack(spacing: 16) {
                    Text(category.title).font(.system(size: FeatureLightfield.titleSize, weight: .bold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let art = category.tabArt {
                        FeatureLightfieldArtwork(art: art, variant: .header)
                            .frame(width: 48, height: 48)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.title.width, height: geometry.title.height, alignment: .leading)
                .lightfieldComponentProbe("settings.title")
                .offset(x: geometry.title.minX, y: geometry.title.minY)
                content
                    .frame(width: geometry.content.width, height: geometry.content.height, alignment: .topLeading)
                    .lightfieldComponentProbe("settings.content")
                    .offset(x: geometry.content.minX, y: geometry.content.minY)
            }
            if category.minimumContentHeight > 0 {
                // D210: a page with a minimum height always sits in a
                // scroll view (resizing past the threshold keeps the page and
                // its selection); the title and the page scroll together only
                // when the window is shorter than the page.
                ScrollView(.vertical) {
                    page
                        .frame(width: viewport.size.width, height: geometry.documentHeight, alignment: .topLeading)
                        .foregroundStyle(palette.fg, palette.fg2, palette.fg3)
                }
                .scrollDisabled(geometry.documentHeight <= viewport.size.height)
            } else {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .foregroundStyle(palette.fg, palette.fg2, palette.fg3)
            }
        }
        // The window's background is clear, so a backdrop that stopped at the
        // title bar left a see-through strip above the pane. Like the main
        // window's D67 pages, it fills the title bar and keeps the halo where
        // the page's canvas puts it.
        .background {
            if drawsBackdrop {
                GeometryReader { proxy in
                    let topInset = proxy.safeAreaInsets.top
                    let canvas = CGSize(width: proxy.size.width, height: max(1, proxy.size.height - topInset))
                    FeatureLightfieldBackdrop(module: .overview, phase: .result,
                        geometry: FeatureLightfieldGeometry(size: canvas, phase: .landing),
                        canvasTopInset: topInset)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

/// D154 batch 3I: CleanMyMac's settings tabs across the top of the window —
/// each page's picture over its name, the current one on a soft block. They
/// replace the D3/D53 sidebar at the user's request (2026-10-21); ← and →
/// move between them, and the version moves to About.
struct SettingsTabBar: View {
    static let height: CGFloat = 72
    // `SettingsCategory.minimumTabWidth` reads these two off the main actor.
    nonisolated static let titleSize: CGFloat = 11
    nonisolated static let tabPadding: CGFloat = 6
    private static let tabSpacing: CGFloat = 2
    private static let sideInset: CGFloat = 12
    /// The least width the tabs lay out at, in the current language. It has to
    /// stay within the window's minimum (`SettingsWindowConfigurator`).
    static var minimumWidth: CGFloat {
        let tabs = SettingsCategory.allCases
        return tabs.map(\.minimumTabWidth).reduce(0, +) + tabSpacing * CGFloat(tabs.count - 1) + 2 * sideInset
    }
    @Environment(\.colorScheme) private var scheme
    let selected: SettingsCategory
    let select: (SettingsCategory) -> Void
    @FocusState private var hasFocus: Bool

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        HStack(spacing: Self.tabSpacing) {
            ForEach(SettingsCategory.allCases) { category in
                let isSelected = selected == category
                Button {
                    select(category)
                    hasFocus = true
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let art = category.tabArt {
                                FeatureLightfieldArtwork(art: art, variant: .header)
                            } else {
                                Image(nsImage: NSApplication.shared.applicationIconImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: 28, height: 28)
                        Text(category.title)
                            .font(.system(size: Self.titleSize, weight: isSelected ? .semibold : .regular))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(palette.fg)
                    .padding(.horizontal, Self.tabPadding)
                    .padding(.vertical, 5)
                    .frame(minWidth: category.minimumTabWidth, maxWidth: 104, minHeight: 60)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FeatureLightfieldPalette.accent(.overview).opacity(scheme == .dark ? 0.20 : 0.16))
                        }
                    }
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .help(category.title)
                .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .lightfieldComponentProbe("settings.tab." + category.rawValue)
            }
        }
        .padding(.horizontal, Self.sideInset)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            move(by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            default: break
            }
        }
        .lightfieldComponentProbe("settings.tabs")
    }

    private func move(by step: Int) {
        guard let current = SettingsCategory.allCases.firstIndex(of: selected) else { return }
        select(SettingsCategory.allCases[min(max(0, current + step), SettingsCategory.allCases.count - 1)])
    }
}

/// B2's hairline, typography and row interaction, without native Form cards.
struct LightfieldSettingsSection<Content: View, Header: View, Footer: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header.font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.fg2)
                .padding(.bottom, 14)
            FeatureLightfieldHairline()
            Group { content }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, minHeight: FeatureLightfield.rowHeight, alignment: .leading)
                .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            footer.font(.system(size: 13)).foregroundStyle(palette.fg2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension LightfieldSettingsSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); self.header = header(); self.footer = EmptyView()
    }
}

struct LightfieldSettingsRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.font(.system(size: 15))
            .frame(maxWidth: .infinity, minHeight: FeatureLightfield.rowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
}

/// D272: the settings row. A title with an optional caption on the left, its
/// control or value on the right; `LightfieldSettingsSection` adds the hairline.
/// Every page uses these rows, so a control is always found in the same place.
/// D273: `detail` is a line right under the caption that stays plain when the
/// caption has its own color; without a caption it does not show.
struct SettingsRow<Control: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var caption: String? = nil
    var captionColor: Color? = nil
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let caption, !caption.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(caption).font(.system(size: 13)).foregroundStyle(captionColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(palette.fg2))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 8)
    }
}

/// D272: the one switch of the settings window (was a checkbox on most pages
/// and a switch on two).
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            .tint(FeatureLightfieldPalette.accent(.overview))
    }
}

struct SettingsToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption) { SettingsSwitch(title: title, isOn: $isOn) }
    }
}

struct SettingsPickerRow<Selection: Hashable, Options: View>: View {
    let title: String
    var caption: String? = nil
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Picker(title, selection: $selection) { options }
                .labelsHidden().pickerStyle(.menu).featureLightfieldMenuTint().fixedSize()
        }
    }
}

struct SettingsValueRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var caption: String? = nil
    let value: String
    var valueColor: Color? = nil

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Text(value).font(.system(size: 13)).foregroundStyle(valueColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(FeatureLightfieldPalette.resolve(scheme).fg2))
                .monospacedDigit().multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// D272: an action reads as one: accent text wherever it sits (was the row's
/// plain text, which looked like a label).
struct SettingsLinkButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(title, role: role, action: action)
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .foregroundStyle(role == .destructive
                ? AppDesignTokens.Palette.destructive
                : FeatureLightfieldPalette.settingsAction)
            .opacity(isEnabled ? 1 : 0.4)
            .fixedSize()
    }
}

/// A row that is one action.
struct SettingsLinkRow: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        SettingsLinkButton(title: title, role: role, action: action).padding(.vertical, 8)
    }
}

/// `LightfieldExpandableRow` as a settings row: the same weight as its neighbours.
struct SettingsExpandableRow<Content: View>: View {
    let title: String
    var metadata = ""
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        LightfieldExpandableRow(title: title, metadata: metadata, titleWeight: .regular,
                                expanded: $expanded) { EmptyView() } content: { content }
    }
}

/// D272: a page without a preview: one column of groups, as wide as a row reads
/// well, in the same scroller as the pages with a preview.
struct SettingsColumn<Content: View>: View {
    static var maximumWidth: CGFloat { 760 }
    @ViewBuilder var content: Content

    var body: some View {
        FeatureOptionsScrollView(probePrefix: "settings.page", balancesContent: false, usesLightfield: true) {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: Self.maximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
        }
    }
}

struct SettingsPalettePicker<Item: Hashable & Identifiable>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let items: [Item]
    @Binding var selection: Item
    let name: (Item) -> String
    let color: (Item) -> Color
    /// A custom item draws a hue ring around its color: before the user picks
    /// one it falls back to a preset and would look exactly like that preset.
    var isCustom: (Item) -> Bool = { _ in false }
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 8) {
            // The selected name sits with the title, not alone at the far
            // side of the swatches.
            HStack(spacing: 8) {
                Text(title).foregroundStyle(palette.fg2)
                Text(name(selection)).foregroundStyle(palette.fg)
            }.font(.system(size: 13)).lineLimit(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    Button { selection = item } label: {
                        swatch(item, palette: palette)
                            .overlay {
                                if selection == item {
                                    Circle().strokeBorder(FeatureLightfieldPalette.accent(.overview), lineWidth: 2)
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(palette.fg)
                                }
                            }.frame(width: 28, height: 28)
                    }.buttonStyle(FeatureLightfieldRowButtonStyle())
                    .help(name(item)).accessibilityLabel(title + " · " + name(item))
                    .accessibilityValue(selection == item ? L10n.text("已选", "Selected") : L10n.text("未选", "Not Selected"))
                }
            }
        }.padding(.vertical, 10)
    }

    @ViewBuilder private func swatch(_ item: Item, palette: FeatureLightfieldPalette) -> some View {
        if isCustom(item) {
            Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .overlay { Circle().fill(color(item)).padding(6) }
        } else {
            // D239＋旧值“1 pt 发丝线（hairColor，12% 不透明）”: near-black themes
            // read as the same dark circle on the night settings background
            // (review P2-14); a 2 pt ring of the foreground sets each apart.
            Circle().fill(color(item))
                .overlay { Circle().strokeBorder(Self.swatchRing(palette, scheme: scheme), lineWidth: 2) }
        }
    }

    static func swatchRing(_ palette: FeatureLightfieldPalette, scheme: ColorScheme) -> Color {
        palette.fg.opacity(scheme == .dark ? 0.34 : 0.2)
    }
}

struct SettingsPreviewColumns<Editor: View, Preview: View, Actions: View>: View {
    @ViewBuilder var editor: Editor
    @ViewBuilder var preview: Preview
    @ViewBuilder var actions: Actions
    /// D272: only the module list applies its changes with buttons; the page
    /// that saves at once has no actions bar.
    private var hasActions: Bool { Actions.self != EmptyView.self }
    var body: some View {
        GeometryReader { viewport in
            if viewport.size.width >= 760 {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The shared options scroller, as on the D67 pages: a bare
                        // ScrollView cut the list just under a row's hairline,
                        // which read as a double line with nothing below it.
                        FeatureOptionsScrollView(probePrefix: "settings.editor", balancesContent: false, usesLightfield: true) {
                            editor.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                        }
                        if hasActions {
                            FeatureLightfieldHairline()
                            actions.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                        }
                    }.frame(width: viewport.size.width - 352)
                    ScrollView { previewContent.padding(.horizontal, 24).padding(.bottom, 8) }
                        .frame(width: 352)
                        .lightfieldComponentProbe("settings.preview.scrollViewport")
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    FeatureOptionsScrollView(probePrefix: "settings.editor", balancesContent: false, usesLightfield: true) {
                        VStack(alignment: .leading, spacing: 24) {
                            editor
                            // The panel keeps its native width even in a 280 pt viewport.
                            ScrollView(.horizontal) { previewContent }
                                .lightfieldComponentProbe("settings.preview.scrollViewport")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                    }
                    .lightfieldComponentProbe("settings.editor.scrollViewport")
                    if hasActions {
                        FeatureLightfieldHairline()
                        actions.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                    }
                }
            }
        }
    }

    private var previewContent: some View {
        preview
            .frame(width: MiniWindowStyleTokens.overviewSize.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .lightfieldComponentProbe("settings.preview.scrollContent")
    }
}
