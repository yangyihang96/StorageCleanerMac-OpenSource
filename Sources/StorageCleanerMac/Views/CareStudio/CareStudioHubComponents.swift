import SwiftUI

/// D154: the frame of a module page that has no round button — CleanMyMac's
/// My Tools and My Activity are a header over a scrolling page on the module
/// gradient. Same backdrop, chrome claim and footnote as `CareStudioPageFrame`.
struct CareStudioHubFrame<Content: View>: View {
    let module: CareStudioModule
    var footnote: String? = nil
    @ViewBuilder let content: Content
    @State private var chromeID = UUID()

    var body: some View {
        ZStack(alignment: .bottom) {
            CareStudioBackdrop(module: module, reportsWindowSize: true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let footnote, !footnote.isEmpty {
                HStack {
                    Spacer()
                    Label(footnote, systemImage: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CareStudioInk.tertiary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
            }
        }
        .environment(\.careStudioSurface, true)
        .onAppear {
            CareStudioCanvas.shared.claim(chromeID, animating: false, label: module.rawValue)
        }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
#if DEBUG
        .layoutProbe("careStudio.page.\(module.rawValue)")
#endif
    }
}

/// Scrolls only when the page is taller than the window, so a page that
/// fits never shows a scroll area (and off-screen renders, which do not
/// draw scroll views, stay complete).
struct CareStudioHubScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Title, subtitle and an optional control on the right (CleanMyMac's My
/// Tools puts its search field there).
struct CareStudioHubHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                titles
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 12) {
                titles
                trailing
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(CareStudioInk.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(CareStudioInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CareStudioHubHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The capsule search field on the gradient ("Search...").
struct CareStudioSearchField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 240

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CareStudioInk.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(CareStudioInk.primary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioInk.tertiary)
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .accessibilityLabel(L10n.text("清除搜索", "Clear Search"))
            }
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: 30)
        .background(Capsule(style: .continuous).fill(CareStudioInk.pillFill))
        .overlay(Capsule(style: .continuous).strokeBorder(CareStudioInk.hairline, lineWidth: 1))
    }
}

/// A glossy mark at any size: our D58 picture turned to a module colour,
/// or in its own colour when `family` is nil (our tools CleanMyMac lacks).
struct CareStudioFamilyMark: View {
    let family: CareStudioFamily?
    var art: GeneratedArt? = nil
    var side: CGFloat = 44

    var body: some View {
        let picture = art ?? family?.art ?? .stateEmpty
        FeatureLightfieldArtwork(art: picture, variant: side > 72 ? .landing : .header)
            .hueRotation(family?.hueRotation(for: picture) ?? .zero)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.28), radius: side * 0.12, y: side * 0.06)
            .accessibilityHidden(true)
    }
}

/// D166: the state picture over a results headline when the scan has
/// nothing to show — the empty box, the all-clear shield, the lock or the
/// warning sign — in its own colours.
struct CareStudioResultsStateMark: View {
    let art: GeneratedArt
    var compact = false

    var body: some View {
        CareStudioFamilyMark(family: nil, art: art, side: compact ? 56 : 88)
            .padding(.top, compact ? 0 : 8)
#if DEBUG
            .layoutProbe("careStudio.results.state")
#endif
    }
}

/// A rounded section title over a card grid ("Favorites", "Other Tools").
struct CareStudioSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioInk.secondary)
                .textCase(nil)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioInk.tertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A translucent card on the gradient, the studio's tile surface.
struct CareStudioCardSurface: ViewModifier {
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                .fill(isHovered ? CareStudioInk.tileFillHover : CareStudioInk.tileFill))
            .overlay(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
    }
}

extension View {
    func careStudioCard(isHovered: Bool = false) -> some View {
        modifier(CareStudioCardSurface(isHovered: isHovered))
    }
}

/// One statistic: label, large value, a short caption (My Activity's cards).
struct CareStudioStatCard<Accessory: View>: View {
    let title: String
    let value: String
    var caption: String? = nil
    var systemImage: String
    var family: CareStudioFamily
    /// D166: the card's object in the corner (My Activity's purple set);
    /// without it the card keeps its round symbol.
    var art: GeneratedArt? = nil
    /// D154 batch 3P: the value counts up when `counted` turns on.
    var counted = true
    var countDelay: Double = 0
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if art == nil {
                    CareStudioFamilyIcon(family: family, systemImage: systemImage, side: 30)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            CareStudioCountingText(value, counted: counted, delay: countDelay)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .monospacedDigit()
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
            Spacer(minLength: 0)
        }
        .padding(CareStudioMetrics.tilePadding)
        .padding(.trailing, art == nil ? 0 : 56)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if let art {
                FeatureLightfieldArtwork(art: art, variant: .header)
                    .hueRotation(CareStudioFamily.myActivity.hueRotation(for: art))
                    .frame(width: 60, height: 60)
                    .shadow(color: CareStudioPalette.color(CareStudioFamily.myActivity.palette.deep, opacity: 0.4), radius: 8, y: 5)
                    .padding(14)
                    .accessibilityHidden(true)
            }
        }
        .careStudioCard()
        .accessibilityElement(children: .combine)
    }
}

extension CareStudioStatCard where Accessory == EmptyView {
    init(title: String, value: String, caption: String? = nil, systemImage: String, family: CareStudioFamily,
         art: GeneratedArt? = nil, counted: Bool = true, countDelay: Double = 0) {
        self.init(title: title, value: value, caption: caption, systemImage: systemImage, family: family,
                  art: art, counted: counted, countDelay: countDelay) { EmptyView() }
    }
}

/// A round glossy icon in a module's button colours (CleanMyMac's small
/// category icons).
struct CareStudioFamilyIcon: View {
    let family: CareStudioFamily
    let systemImage: String
    var side: CGFloat = 32

    var body: some View {
        let palette = family.palette
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [CareStudioPalette.color(palette.action[0]),
                                              CareStudioPalette.color(palette.action[1])],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.32), .clear],
                                     startPoint: .top, endPoint: .center))
                .padding(2)
            Image(systemName: systemImage)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .shadow(color: CareStudioPalette.color(palette.deep, opacity: 0.4), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}

/// A segmented bar of parts of a total (My Activity's breakdown, Space
/// Map's usage bar).
struct CareStudioSegmentBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let value: Int64
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        let total = max(1, segments.reduce(Int64(0)) { $0 + max(0, $1.value) })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
                        Capsule(style: .continuous)
                            .fill(segment.color)
                            .frame(width: max(4, proxy.size.width * CGFloat(segment.value) / CGFloat(total)))
                    }
                    Spacer(minLength: 0)
                }
                .background(Capsule(style: .continuous).fill(CareStudioInk.pillFill))
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: height)
            CareStudioFlowLayout(spacing: 12, lineSpacing: 6) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 7, height: 7)
                        Text(segment.title)
                            .font(.system(size: 11))
                            .foregroundStyle(CareStudioInk.secondary)
                        Text(ByteFormat.storageString(segment.value))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CareStudioInk.primary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
