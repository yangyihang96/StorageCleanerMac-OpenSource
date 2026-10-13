import AppKit
import SwiftUI

/// UI-V2-SPEC 1.5 illustration language: concentric orbits with gradient
/// strokes, a large glowing center mark and
/// star points. Day and night share the same drawing (audit G7). It plays its
/// entrance once when it appears; the orbit sweep only turns while `isActive`
/// (a scan is running) and never under Reduce Motion (§3.3).
///
/// Sizes (main session review of the V0 samples): the whole drawing is
/// 380–420 pt in `regular` and 480–560 pt in `wide`/`tall`; the center mark
/// is at least 150 pt. Satellites are removed by D64.
struct OrbitLandingArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var moduleTheme
    @AppSurfaces private var surfaces
    @State private var hasEntered = false
    @State private var isVisible = false

    let centerGlyph: IconTile.Glyph
    var isActive = false
    /// D58: the module's generated mark in the center; the orbits,
    /// stars and halo stay code-drawn. Without the file, the glossy orb.
    var centerArt: GeneratedArt?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // Review P2-8: the drawing is sized and placed so the orbits, the center remain inside the square.
            let geometry = OrbitArtworkGeometry.resolve(side: side)
            let drawing = geometry.drawing
            let bleed = max(32, side * 0.16)
            let shift = CGSize(width: geometry.center.x - side / 2, height: geometry.center.y - side / 2)
            // Three layers: the static back (halo, orbits, stars) and front
            // (center mark) are each composited once; the sweep between
            // them turns in the render server, so a running scan costs no
            // per-frame work in the app (§3.3).
            ZStack {
                ZStack {
                    halo(side: drawing)
                    orbits(side: drawing)
                    stars(side: drawing)
                }
                .offset(shift)
                .frame(width: side, height: side)
                .padding(bleed)
                .drawingGroup()
                .padding(-bleed)
                if isActive {
                    sweepArc(side: drawing)
                        .offset(shift)
                        .frame(width: side, height: side)
                }
                ZStack {
                    centerMark(side: drawing)
                        .offset(shift)

                }
                .frame(width: side, height: side)
                .padding(bleed)
                .drawingGroup()
                .padding(-bleed)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            isVisible = true
            guard !hasEntered else { return }
            withAnimation(reduceMotion ? AppMotion.reducedFade : AppMotion.emphasized) {
                hasEntered = true
            }
        }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var tint: ModulePigment {
        moduleTheme.isImmersive ? moduleTheme.pigment : .smartScan
    }

    private var accentColors: [Color] {
        [tint.brightColor, ModulePigment.memory.brightColor, ModulePigment.files.brightColor, tint.brightColor]
    }

    private static func centerSide(for side: CGFloat) -> CGFloat {
        min(side * 0.42, max(150, side * 0.34))
    }

    // MARK: Layers

    private func halo(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [tint.brightColor.opacity(surfaces.isNight ? 0.42 : 0.22),
                             ModulePigment.memory.brightColor.opacity(surfaces.isNight ? 0.12 : 0.06),
                             .clear],
                    center: .center, startRadius: 0, endRadius: side * 0.50
                ))
            Circle()
                .fill(RadialGradient(
                    colors: [tint.brightColor.opacity(surfaces.isNight ? 0.30 : 0.16), .clear],
                    center: .center, startRadius: 0, endRadius: side * 0.24
                ))
        }
        .opacity(hasEntered ? 1 : 0)
        .animation(entrance(delay: 0), value: hasEntered)
    }

    private func orbits(side: CGFloat) -> some View {
        ZStack {
            ForEach(Array([CGFloat(0.50), 0.64].enumerated()), id: \.offset) { index, fraction in
                Circle()
                    .stroke(
                        AngularGradient(colors: accentColors.map { $0.opacity(surfaces.isNight ? 0.34 : 0.30) },
                                        center: .center),
                        lineWidth: index == 0 ? 1.2 : 1
                    )
                    .frame(width: side * fraction, height: side * fraction)
                    .scaleEffect(AppMotion.entranceScale(from: 0.9, hasEntered: hasEntered, reduceMotion: reduceMotion))
                    .opacity(hasEntered ? 1 : 0)
                    .animation(entrance(delay: Double(index) * 0.06), value: hasEntered)
            }
            Circle()
                .stroke(
                    AngularGradient(colors: accentColors.map { $0.opacity(0.95) }, center: .center),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2.5, 7])
                )
                .frame(width: side * 0.80, height: side * 0.80)
                .shadow(color: tint.brightColor.opacity(surfaces.isNight ? 0.6 : 0.25), radius: 4)
                .scaleEffect(AppMotion.entranceScale(from: 0.94, hasEntered: hasEntered, reduceMotion: reduceMotion))
                .opacity(hasEntered ? 1 : 0)
                .animation(entrance(delay: 0.12), value: hasEntered)
        }
    }

    /// Star points: four-pointed sparkles and small dots on the orbits.
    private func stars(side: CGFloat) -> some View {
        let sparkles: [(angle: Double, radius: CGFloat, size: CGFloat, color: Color)] = [
            (-62, 0.43, 0.050, tint.brightColor),
            (24, 0.30, 0.034, ModulePigment.files.brightColor),
            (150, 0.43, 0.040, ModulePigment.memory.brightColor),
            // Inside the inner orbit, clear of the top-left node's label.
            (196, 0.22, 0.026, .white),
        ]
        let dots: [(angle: Double, radius: CGFloat, size: CGFloat, color: Color)] = [
            (-100, 0.26, 7, tint.brightColor), (-12, 0.43, 8, ModulePigment.memory.brightColor),
            (60, 0.34, 6, ModulePigment.files.brightColor), (128, 0.26, 5, .white),
            (185, 0.43, 7, tint.brightColor), (250, 0.34, 6, ModulePigment.memory.brightColor),
        ]
        return ZStack {
            ForEach(Array(sparkles.enumerated()), id: \.offset) { index, star in
                SparkleShape()
                    .fill(LinearGradient(colors: [.white, star.color], startPoint: .top, endPoint: .bottom))
                    .frame(width: side * star.size, height: side * star.size)
                    .shadow(color: star.color.opacity(0.9), radius: 6)
                    .offset(x: cos(star.angle * .pi / 180) * side * star.radius,
                            y: sin(star.angle * .pi / 180) * side * star.radius)
                    .scaleEffect(AppMotion.entranceScale(from: 0.4, hasEntered: hasEntered, reduceMotion: reduceMotion))
                    .opacity(hasEntered ? 1 : 0)
                    .animation(entrance(delay: 0.28 + Double(index) * 0.05), value: hasEntered)
            }
            ForEach(Array(dots.enumerated()), id: \.offset) { index, dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: dot.size, height: dot.size)
                    .shadow(color: dot.color.opacity(0.85), radius: 4)
                    .offset(x: cos(dot.angle * .pi / 180) * side * dot.radius,
                            y: sin(dot.angle * .pi / 180) * side * dot.radius)
                    .opacity(hasEntered ? 0.95 : 0)
                    .animation(entrance(delay: 0.2 + Double(index) * 0.03), value: hasEntered)
            }
        }
    }

    /// The scanning sweep: a Core Animation layer that turns in the render
    /// server; Reduce Motion shows the arc still (§3.3).
    private func sweepArc(side: CGFloat) -> some View {
        OrbitSweepLayer(color: NSColor(tint.brightColor), turns: AppMotion.runsOrbit(isActive: isActive, isVisible: isVisible, reduceMotion: reduceMotion))
            .frame(width: side * 0.68 + 24, height: side * 0.68 + 24)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func centerMark(side: CGFloat) -> some View {
        let disc = Self.centerSide(for: side)
        return ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(colors: accentColors.map { $0.opacity(0.55) }, center: .center),
                    lineWidth: 1.5
                )
                .frame(width: disc * 1.22, height: disc * 1.22)
            // The picture carries its own glass and glow; it fills the ring
            // (its file has a transparent margin). Until it is loaded, or
            // without the file, the glossy orb stands in.
            GeneratedArtView(art: centerArt, variant: .landing) {
                ZStack {
                    Circle()
                        .fill(tint.brightColor.opacity(surfaces.isNight ? 0.10 : 0.08))
                        .frame(width: disc * 1.12, height: disc * 1.12)
                    GlossyOrb(glyph: centerGlyph, side: disc, pigment: tint, glowRadius: disc * 0.42)
                }
            }
            .frame(width: disc * 1.2, height: disc * 1.2)
        }
        .scaleEffect(AppMotion.entranceScale(from: 0.86, hasEntered: hasEntered, reduceMotion: reduceMotion))
        .opacity(hasEntered ? 1 : 0)
        .animation(entrance(delay: 0.04), value: hasEntered)
    }

    private func entrance(delay: Double) -> Animation? {
        reduceMotion ? AppMotion.reducedFade : AppMotion.emphasized.delay(delay)
    }

}

/// D64: centered main artwork, rings and bounded glow; no satellite views.
struct OrbitArtworkGeometry: Equatable {
    static let margin: CGFloat = 4
    let side: CGFloat
    let drawing: CGFloat
    let center: CGPoint

    static func resolve(side: CGFloat) -> OrbitArtworkGeometry {
        let side = max(0, side)
        return OrbitArtworkGeometry(side: side, drawing: max(0, side - margin * 2),
            center: CGPoint(x: side / 2, y: side / 2))
    }

    var outerOrbitBounds: CGRect {
        let radius = drawing * 0.40
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// A glowing arc (a fifth of the ring, fading in toward its head) that
/// turns once every 2.4 s with a layer animation. It exists only while a
/// scan or measurement runs (`OrbitLandingArtwork.isActive`).
private struct OrbitSweepLayer: NSViewRepresentable {
    let color: NSColor
    let turns: Bool

    func makeNSView(context: Context) -> OrbitSweepView {
        OrbitSweepView()
    }

    func updateNSView(_ view: OrbitSweepView, context: Context) {
        view.configure(color: color, turns: turns)
    }
}

final class OrbitSweepView: NSView {
    private let spinner = CALayer()
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var turns = true
    private var hasPublishedOcclusionState = false
    static let rotationKey = "orbit.sweep.rotation"

    /// Whether the layer animation is installed (tests).
    var isTurning: Bool { spinner.animation(forKey: Self.rotationKey) != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = 3
        gradient.mask = ring
        spinner.addSublayer(gradient)
        spinner.shadowOpacity = 0.7
        spinner.shadowRadius = 6
        spinner.shadowOffset = .zero
        layer?.addSublayer(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(color: NSColor, turns: Bool) {
        self.turns = turns
        let resolved = color.usingColorSpace(.sRGB) ?? color
        gradient.colors = [
            resolved.withAlphaComponent(0).cgColor,
            resolved.withAlphaComponent(0.9).cgColor,
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.locations = [0, 0.2, 0.2001, 1]
        spinner.shadowColor = resolved.cgColor
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset: CGFloat = 12
        spinner.bounds = bounds
        spinner.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        gradient.frame = bounds
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        // A view inserted into an already ordered window can use that
        // window's published visibility. A newly attached hidden window
        // bootstraps from isVisible until its first server notification.
        hasPublishedOcclusionState = window?.isVisible == true
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged(_:)),
                                                       name: name, object: window)
            }
        }
        updateAnimation()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.didChangeOcclusionStateNotification {
            hasPublishedOcclusionState = true
        }
        updateAnimation()
    }

    private func updateAnimation() {
        // isVisible handles ordering immediately. Once the window server
        // publishes occlusion, a fully covered window also stops the sweep.
        guard turns, window != nil, window?.isVisible == true, window?.isMiniaturized == false,
              !isHiddenOrHasHiddenAncestor,
              !hasPublishedOcclusionState || window?.occlusionState.contains(.visible) == true else {
            spinner.removeAnimation(forKey: Self.rotationKey)
            return
        }
        guard spinner.animation(forKey: Self.rotationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        // Clockwise on screen (the layer's y axis points up).
        rotation.toValue = -2 * Double.pi
        rotation.duration = AppMotion.orbitRotationDuration
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        spinner.add(rotation, forKey: Self.rotationKey)
    }
}

/// A glossy sphere: module gradient, a specular highlight at the top-left,
/// a light rim and an outer glow, with a white glyph.
struct GlossyOrb: View {
    @Environment(\.colorScheme) private var colorScheme
    let glyph: IconTile.Glyph
    let side: CGFloat
    let pigment: ModulePigment
    var glowRadius: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [pigment.brightColor, pigment.lightStop, pigment.darkStop],
                    center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: side * 0.72
                ))
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                     center: UnitPoint(x: 0.34, y: 0.22), startRadius: 0, endRadius: side * 0.36))
                .blendMode(.screen)
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.65), pigment.brightColor.opacity(0.35), .white.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(1, side * 0.02)
                )
            glyphView
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: side * 0.03, y: side * 0.02)
        }
        .frame(width: side, height: side)
        .shadow(color: pigment.brightColor.opacity(colorScheme == .dark ? 0.75 : 0.40), radius: glowRadius)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            AppSymbolGlyph(systemImage: name, size: (side * 0.44).rounded(), weight: .semibold)
        case .smartScanEmblem:
            SmartScanEmblem()
                .frame(width: side * 0.56, height: side * 0.56)
        }
    }
}

/// A four-pointed star.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.28
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

extension OrbitLandingArtwork {
    // All phases use the same center-only artwork, with activity supplied by the caller.
    static func smartScan(isActive: Bool = false) -> OrbitLandingArtwork {
        OrbitLandingArtwork(centerGlyph: .smartScanEmblem, isActive: isActive, centerArt: .smartScan)
    }

    static func module(systemImage: String,
        isActive: Bool = false) -> OrbitLandingArtwork {
        OrbitLandingArtwork(centerGlyph: .symbol(systemImage), isActive: isActive,
            centerArt: GeneratedArt.module(forSystemImage: systemImage))
    }
}
