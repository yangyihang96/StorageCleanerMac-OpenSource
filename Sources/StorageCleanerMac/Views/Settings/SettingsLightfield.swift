import SwiftUI

/// Frozen B6 geometry. The preview owns its natural height; only its viewport scrolls.
/// D210: a page with a minimum content height (the ignore list) keeps
/// it in a shorter window; the footer follows the content and the whole page
/// scrolls (`documentHeight` past the viewport). Other pages are unchanged.
struct SettingsLightfieldGeometry: Equatable {
    let title: CGRect
    let content: CGRect
    let footer: CGRect
    let hasPreview: Bool
    /// The page's height: the viewport's, unless the page scrolls.
    let documentHeight: CGFloat

    init(size: CGSize, category: SettingsCategory) {
        hasPreview = category == .general || category == .miniWindow
        let inset: CGFloat = hasPreview ? (size.width >= 760 ? 52 : 24) : (size.width >= 920 ? 96 : 24)
        let titleY: CGFloat = hasPreview ? 12 : (size.height >= 650 ? 92 : 24)
        let contentY: CGFloat = hasPreview ? 64 : titleY + 84
        title = CGRect(x: inset, y: titleY, width: max(0, size.width - inset - (hasPreview ? 24 : inset)), height: 48)
        let frozenFooter = CGRect(x: inset, y: max(contentY, size.height - 108), width: max(0, size.width - inset - (hasPreview ? 24 : inset)), height: min(108, max(0, size.height - contentY)))
        let frozenContent = CGRect(x: inset, y: contentY, width: max(0, size.width - inset - (hasPreview ? 24 : inset)),
            height: max(0, (hasPreview ? size.height : frozenFooter.minY - 24) - contentY))
        if !hasPreview, frozenContent.height < category.minimumContentHeight {
            content = CGRect(x: inset, y: contentY, width: frozenContent.width, height: category.minimumContentHeight)
            footer = CGRect(x: inset, y: content.maxY + 24, width: frozenFooter.width, height: 108)
            documentHeight = max(size.height, footer.maxY)
        } else {
            content = frozenContent
            footer = frozenFooter
            documentHeight = size.height
        }
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
                if !geometry.hasPreview {
                    VStack(alignment: .leading, spacing: 20) {
                        FeatureLightfieldHairline()
                        Text(L10n.text("偏好更改即时保存；系统操作仍需你明确执行。", "Preferences save immediately; system actions require your explicit action."))
                            .font(.system(size: 13)).foregroundStyle(palette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(width: geometry.footer.width, height: geometry.footer.height, alignment: .topLeading)
                    .lightfieldComponentProbe("settings.footer")
                    .offset(x: geometry.footer.minX, y: geometry.footer.minY)
                }
            }
            if category.minimumContentHeight > 0 {
                // D210: a page with a minimum height always sits in a
                // scroll view (resizing past the threshold keeps the page and
                // its selection); the title, the page and the footer scroll
                // together only when the window is shorter than the page.
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
                    FeatureLightfieldBackdrop(module: .overview, phase: .landing,
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
    @Environment(\.colorScheme) private var scheme
    let selected: SettingsCategory
    let select: (SettingsCategory) -> Void
    @FocusState private var hasFocus: Bool

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        HStack(spacing: 2) {
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
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(palette.fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(minWidth: 64, maxWidth: 104, minHeight: 60)
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
        .padding(.horizontal, 12)
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
            Circle().fill(color(item))
                .overlay { Circle().strokeBorder(palette.hairColor, lineWidth: 1) }
        }
    }
}

struct SettingsPreviewColumns<Editor: View, Preview: View, Actions: View>: View {
    @ViewBuilder var editor: Editor
    @ViewBuilder var preview: Preview
    @ViewBuilder var actions: Actions
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
                        FeatureLightfieldHairline()
                        actions.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
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
                    FeatureLightfieldHairline()
                    actions.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
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
