import SwiftUI

/// Frozen B6 geometry. The preview owns its natural height; only its viewport scrolls.
struct SettingsLightfieldGeometry: Equatable {
    let title: CGRect
    let content: CGRect
    let footer: CGRect
    let hasPreview: Bool

    init(size: CGSize, category: SettingsCategory) {
        hasPreview = category == .general || category == .miniWindow
        let inset: CGFloat = hasPreview ? (size.width >= 760 ? 52 : 24) : (size.width >= 920 ? 96 : 24)
        let titleY: CGFloat = hasPreview ? 12 : (size.height >= 650 ? 92 : 24)
        let contentY: CGFloat = hasPreview ? 64 : titleY + 84
        title = CGRect(x: inset, y: titleY, width: max(0, size.width - inset - (hasPreview ? 24 : inset)), height: 48)
        footer = CGRect(x: inset, y: max(contentY, size.height - 108), width: max(0, size.width - inset - (hasPreview ? 24 : inset)), height: min(108, max(0, size.height - contentY)))
        content = CGRect(x: inset, y: contentY, width: max(0, size.width - inset - (hasPreview ? 24 : inset)),
            height: max(0, (hasPreview ? size.height : footer.minY - 24) - contentY))
    }
}

extension SettingsCategory {
    var artworkModule: ReviewFilter {
        switch self {
        case .general: .overview
        case .miniWindow: .memory
        case .scanAndSafety: .green
        case .accessAndSetup: .privacy
        case .systemControl: .healthHub
        case .updates: .updater
        case .about: .largeFiles
        }
    }
}

struct SettingsLightfieldPane<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let category: SettingsCategory
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { viewport in
            let geometry = SettingsLightfieldGeometry(size: viewport.size, category: category)
            let palette = FeatureLightfieldPalette.resolve(scheme)
            ZStack(alignment: .topLeading) {
                FeatureLightfieldBackdrop(module: .overview, phase: .landing,
                    geometry: FeatureLightfieldGeometry(size: viewport.size, phase: .landing))
                HStack(spacing: 16) {
                    Text(category.title).font(.system(size: FeatureLightfield.titleSize, weight: .bold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if category != .about {
                        FeatureLightfieldArtwork(art: GeneratedArt.module(for: category.artworkModule), variant: .header)
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
            }.foregroundStyle(palette.fg, palette.fg2, palette.fg3)
        }
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
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(palette.fg2)
            HStack(alignment: .top, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        Button { selection = item } label: {
                            Circle().fill(color(item))
                                .overlay { Circle().strokeBorder(palette.hairColor, lineWidth: 1) }
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
                Text(name(selection)).font(.system(size: 13)).foregroundStyle(palette.fg2)
                    .frame(width: 96, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 10)
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
                        ScrollView { editor.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24) }
                        FeatureLightfieldHairline()
                        actions.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                    }.frame(width: viewport.size.width - 352)
                    ScrollView { previewContent.padding(.horizontal, 24).padding(.bottom, 8) }
                        .frame(width: 352)
                        .lightfieldComponentProbe("settings.preview.scrollViewport")
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
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
