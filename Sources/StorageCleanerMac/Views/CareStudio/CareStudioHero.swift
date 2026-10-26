import SwiftUI

/// The module picture: our D58 glossy 3D mark recoloured to the module.
/// While a module works it floats and tilts slightly (CleanMyMac rocks its
/// picture while scanning); Reduce Motion keeps it still.
struct CareStudioArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let module: CareStudioModule
    var side: CGFloat = CareStudioMetrics.landingArtSide
    var isWorking = false
    /// A finished cleanup shows the success mark instead of the module mark.
    var showsSuccess = false
    /// A page's own picture (Similar Photos on the duplicates page), turned
    /// to the module colour like the module's; a state picture (D166) keeps
    /// its own colour.
    var art: GeneratedArt? = nil
    /// D154: a landing's picture swings in from below when the page opens
    /// (CleanMyMac's badge intro); a success mark pops with a ring of light.
    var entrance = false
    @State private var arrived = false

    private var still: Bool { reduceMotion || disablesAnimations }
    private var arrives: Bool { (entrance || showsSuccess) && !still }

    var body: some View {
        let pose = Self.arrivalPose(entrance: entrance, success: showsSuccess, still: still, arrived: arrived)
        Group {
            if isWorking && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    picture(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                picture(time: nil)
            }
        }
        .scaleEffect(pose.scale)
        .rotationEffect(.degrees(pose.rotation))
        .offset(y: side * pose.lift)
        .opacity(pose.opacity)
        .background {
            if showsSuccess && arrives {
                CareStudioCelebrationRing(color: CareStudioPalette.color(module.palette.actionGlow),
                                          side: side, arrived: arrived)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .onAppear {
            guard arrives, !arrived else { return }
            withAnimation(showsSuccess ? CareStudioMotion.successPop : CareStudioMotion.artArrival) { arrived = true }
        }
#if DEBUG
        .layoutProbe("careStudio.art")
#endif
    }

    /// Where the picture starts before it arrives; at rest (or still) it is
    /// the picture itself. `lift` is a fraction of the picture's side.
    static func arrivalPose(entrance: Bool, success: Bool, still: Bool, arrived: Bool)
        -> (scale: CGFloat, rotation: Double, lift: CGFloat, opacity: Double) {
        guard !still, !arrived, entrance || success else { return (1, 0, 0, 1) }
        return success ? (0.6, 0, 0, 0) : (0.86, -10, 0.16, 0)
    }

    private func picture(time: TimeInterval?) -> some View {
        let phase = time.map { ($0 / CareStudioMotion.artFloatPeriod) * 2 * .pi } ?? 0
        let lift = time == nil ? 0 : CGFloat(sin(phase)) * CareStudioMotion.artFloatDistance
        let tilt = time == nil ? 0 : sin(phase * 0.5) * CareStudioMotion.artTilt
        return ZStack {
            if let time, isWorking {
                // D154: a slow ring of light turns behind a working picture,
                // in place of CleanMyMac's Metal aurora.
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(AngularGradient(colors: [CareStudioPalette.color(module.palette.actionGlow, opacity: 0),
                                                     CareStudioPalette.color(module.palette.actionGlow, opacity: 0.55),
                                                     CareStudioPalette.color(module.palette.halo[1], opacity: 0)],
                                            center: .center),
                            style: StrokeStyle(lineWidth: max(2, side * 0.022), lineCap: .round))
                    .frame(width: side * 1.06, height: side * 1.06)
                    .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: CareStudioMotion.glowRingPeriod)
                                             / CareStudioMotion.glowRingPeriod * 360))
                    .blur(radius: 2.5)
            }
            // Soft light under the picture.
            Ellipse()
                .fill(CareStudioPalette.color(module.palette.actionGlow, opacity: 0.38))
                .frame(width: side * 0.78, height: side * 0.2)
                .offset(y: side * 0.40)
                .blur(radius: 18)
            if isWorking {
                // CleanMyMac leaves a faint trail behind the moving picture.
                artwork
                    .opacity(0.22)
                    .offset(x: -side * 0.08, y: side * 0.04 - lift * 0.5)
                    .rotation3DEffect(.degrees(tilt * 1.6), axis: (x: 0.2, y: 1, z: 0))
                    .blur(radius: 2)
            }
            artwork
                .offset(y: -lift)
                .rotation3DEffect(.degrees(tilt), axis: (x: 0.2, y: 1, z: 0))
        }
    }

    private var artwork: some View {
        FeatureLightfieldArtwork(art: showsSuccess ? .stateCelebration : (art ?? module.art), variant: .landing)
            .hueRotation(showsSuccess ? CareStudioModule.successHue(for: module) : artHue)
            .shadow(color: CareStudioPalette.color(module.palette.deep, opacity: 0.5), radius: 16, y: 10)
    }
}

extension CareStudioArt {
    fileprivate var artHue: Angle {
        guard let art, art != module.art else { return module.artHueRotation }
        return module.family == .myTools || art.keepsOwnColour ? .zero : module.family.hueRotation(for: art)
    }
}

extension CareStudioModule {
    /// D166: a finished task shows the celebration mark (a tick badge with
    /// confetti), turned to the module colour by its measured hue; our own
    /// tools keep it green.
    static func successHue(for module: CareStudioModule) -> Angle {
        switch module {
        case .health, .benchmark, .energy, .migration: .zero
        default: module.family.hueRotation(for: .stateCelebration)
        }
    }
}

/// One line of the landing list (CleanMyMac lists three or four things a
/// module covers, by name only — D204). Rows bound to a scan scope toggle
/// it; others are plain.
struct CareStudioBullet: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// A reading under the name (the memory page's figures); module landings
    /// have none.
    var detail: String? = nil
    /// What the line covers, for VoiceOver only (D204: the line under the
    /// name went, as on CleanMyMac's landings).
    var hint: String? = nil
    /// nil: an informative row. Non-nil: a scope that can be turned off.
    var isSelected: Bool? = nil
    var toggle: (() -> Void)? = nil
}

struct CareStudioBulletRow: View {
    let module: CareStudioModule
    let bullet: CareStudioBullet
    @State private var isHovered = false

    var body: some View {
        Group {
            if let toggle = bullet.toggle {
                Button(action: toggle) { content }
                    .buttonStyle(CareStudioRowButtonStyle())
                    .onHover { isHovered = $0 }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(bullet.isSelected == true
                        ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(bullet.hint ?? "")
#if DEBUG
        .layoutProbe("careStudio.bullet.\(bullet.id)")
#endif
    }

    private var content: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [CareStudioPalette.color(module.palette.action[0]),
                                 CareStudioPalette.color(module.palette.action[1])],
                        startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                    }
                Image(systemName: bullet.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: CareStudioMetrics.bulletIconSide, height: CareStudioMetrics.bulletIconSide)
            .opacity(bullet.isSelected == false ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(bullet.title)
                    .font(.system(size: CareStudioMetrics.bulletSize, weight: .semibold))
                    .foregroundStyle(bullet.isSelected == false ? CareStudioInk.tertiary : CareStudioInk.primary)
                    .lineLimit(1)
                if let detail = bullet.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioInk.tertiary)
                        .lineLimit(1)
                }
            }

            if let isSelected = bullet.isSelected {
                Spacer(minLength: 12)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? CareStudioInk.primary : CareStudioInk.tertiary)
                    .opacity(isHovered || !isSelected ? 1 : 0.85)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Title, subtitle and list of a landing page.
struct CareStudioHeadline: View {
    let module: CareStudioModule
    var title: String? = nil
    var subtitle: String? = nil
    var bullets: [CareStudioBullet] = []
    var status: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title ?? module.title)
                .font(.system(size: compact ? 30 : CareStudioMetrics.titleSize, weight: .light))
                .foregroundStyle(CareStudioInk.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
#if DEBUG
                .layoutProbe("careStudio.title")
#endif
            Text(subtitle ?? module.subtitle)
                .font(.system(size: compact ? 14 : CareStudioMetrics.subtitleSize))
                .foregroundStyle(CareStudioInk.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 6 : 10)
            if !bullets.isEmpty {
                // Names alone keep CleanMyMac's 52 pt pitch; a reading under
                // the name takes some of it.
                VStack(alignment: .leading, spacing: compact ? 12
                       : bullets.contains { $0.detail != nil } ? CareStudioMetrics.bulletSpacing
                       : CareStudioMetrics.bulletNameSpacing) {
                    ForEach(bullets) { bullet in
                        CareStudioBulletRow(module: module, bullet: bullet)
                    }
                }
                .padding(.top, compact ? 16 : 26)
            }
            if let status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioInk.tertiary)
                    .lineLimit(2)
                    .padding(.top, compact ? 14 : 22)
#if DEBUG
                    .layoutProbe("careStudio.status")
#endif
            }
        }
    }
}

/// D154: the ring of light that spreads once around a success mark.
private struct CareStudioCelebrationRing: View {
    let color: Color
    let side: CGFloat
    let arrived: Bool

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(color, lineWidth: index == 0 ? 3 : 1.5)
                    .frame(width: side * 0.78, height: side * 0.78)
                    .scaleEffect(arrived ? 1.55 + CGFloat(index) * 0.25 : 0.7)
                    .opacity(arrived ? 0 : 0.7)
                    .animation(.easeOut(duration: 0.9).delay(0.12 + Double(index) * 0.12), value: arrived)
            }
        }
        .allowsHitTesting(false)
    }
}
