import SwiftUI

/// A D58 picture (`GeneratedArt`) drawn to fit its frame. Decorative: it is
/// hidden from VoiceOver, the page title or status says what it means. Until
/// the picture is loaded (off the main thread, review P2-4), and when the
/// file is missing (a damaged bundle), the code-drawn `fallback` takes its
/// place, so nothing waits, crashes or stays empty.
struct GeneratedArtView<Fallback: View>: View {
    @Environment(\.generatedArtLibrary) private var library
    @Environment(\.generatedArtWindowVisible) private var artWindowVisible
    @AppSurfaces private var surfaces
    @State private var loaded: Loaded?
    let art: GeneratedArt?
    let variant: GeneratedArt.Variant
    @ViewBuilder let fallback: Fallback

    private struct Loaded {
        let name: String
        let image: CGImage
    }

    private var resourceName: String? {
        art?.resourceName(variant)
    }

    var body: some View {
        let name = resourceName
        let image = name.flatMap { name in
            loaded?.name == name ? loaded?.image : library.cachedImage(named: name)
        }
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    // Daylight: the pictures carry their own soft glow; on the
                    // ivory canvas it is kept a little tighter so it does not
                    // read as a smudge (D58 ⑤).
                    .saturation(surfaces.isNight ? 1 : 1.04)
                    .contrast(surfaces.isNight ? 1 : 1.03)
                    .accessibilityHidden(true)
                    .transition(.opacity)
#if DEBUG
                    .layoutProbe("generatedArt.image.\(name ?? "")")
#endif
            } else {
                fallback
#if DEBUG
                    .layoutProbe("generatedArt.fallback.\(name ?? "none")")
#endif
            }
        }
        .task(id: GeneratedArtLoadRequest(name: name, visible: artWindowVisible)) {
            guard artWindowVisible else { return }
            // Always ask the library and publish what it returns, also when
            // the picture is already cached: a preload may have filled the
            // cache after this view's first `body` showed the fallback, and
            // the cache itself does not redraw views (review 2, P2-2).
            guard let name, let image = await library.image(named: name), !Task.isCancelled,
                  loaded?.name != name || loaded?.image !== image else { return }
            // The fallback gives way with a fade (also under Reduce Motion).
            withAnimation(AppMotion.reducedFade) {
                loaded = Loaded(name: name, image: image)
            }
        }
    }
}

extension GeneratedArtView where Fallback == EmptyView {
    init(art: GeneratedArt?, variant: GeneratedArt.Variant) {
        self.art = art
        self.variant = variant
        self.fallback = EmptyView()
    }
}

/// An illustrated state (D58 `state-*`): the picture, a title and an
/// optional detail, centered on a card. Without the picture, the symbol
/// tile of the earlier empty states.
struct StateArtPanel: View {
    enum Arrangement {
        /// Picture above the text, for a page that has nothing else to show.
        case stacked
        /// Picture beside the text, as a banner above other content.
        case banner
    }

    @AppSurfaces private var surfaces
    let art: GeneratedArt
    let fallbackSystemImage: String
    let title: String
    var detail: String?
    var arrangement: Arrangement = .stacked

    var body: some View {
        Group {
            switch arrangement {
            case .stacked:
                VStack(spacing: AppDesignTokens.Grid.x1_5) {
                    picture(side: 132)
                    copy(alignment: .center)
                }
                .padding(AppDesignTokens.Grid.x3)
                .frame(maxWidth: .infinity)
            case .banner:
                HStack(spacing: AppDesignTokens.Grid.x2) {
                    picture(side: 72)
                    copy(alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(AppDesignTokens.Grid.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card)
        }
        .accessibilityElement(children: .combine)
    }

    private func picture(side: CGFloat) -> some View {
        GeneratedArtView(art: art, variant: .landing) {
            IconTile(systemImage: fallbackSystemImage, side: side * 0.5)
        }
        .frame(width: side, height: side)
    }

    private func copy(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: AppDesignTokens.Grid.x0_5) {
            Text(title)
                .font(AppDesignTokens.TypeScale.sectionTitle)
                .foregroundStyle(surfaces.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppDesignTokens.TypeScale.secondary)
                    .foregroundStyle(surfaces.textSecondary)
                    .frame(maxWidth: PageLayout.readableLineWidth, alignment: alignment == .center ? .center : .leading)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// D58: a state picture for an initial-style page (a terminal Smart Scan
/// page that failed or finished without a report). `nil` keeps the module
/// drawing.
private struct LandingStateArtKey: EnvironmentKey {
    static let defaultValue: GeneratedArt? = nil
}

extension EnvironmentValues {
    var landingStateArt: GeneratedArt? {
        get { self[LandingStateArtKey.self] }
        set { self[LandingStateArtKey.self] = newValue }
    }
}

/// The landing illustration for a state: the picture with the module halo,
/// entering once (no idle loop, §3.3).
struct StateLandingArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var moduleTheme
    @AppSurfaces private var surfaces
    @State private var hasEntered = false
    let art: GeneratedArt
    let fallbackSystemImage: String

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let tint = moduleTheme.isImmersive ? moduleTheme.pigment : .neutral
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [tint.brightColor.opacity(surfaces.isNight ? 0.30 : 0.14), .clear],
                        center: .center, startRadius: 0, endRadius: side * 0.48
                    ))
                GeneratedArtView(art: art, variant: .landing) {
                    IconTile(systemImage: fallbackSystemImage, side: side * 0.3, glows: true)
                }
                .frame(width: side * 0.62, height: side * 0.62)
                .scaleEffect(AppMotion.entranceScale(from: 0.9, hasEntered: hasEntered, reduceMotion: reduceMotion))
            }
            .opacity(hasEntered ? 1 : 0)
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !hasEntered else { return }
            withAnimation(reduceMotion ? AppMotion.reducedFade : AppMotion.emphasized) {
                hasEntered = true
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
