import SwiftUI

/// The size of the window the studio gradient spans. The detail column
/// reports it (its trailing edge is the window's); the sidebar reads it so
/// both columns draw one continuous gradient, as CleanMyMac's sidebar sits
/// on the module colour instead of its own fill.
@MainActor
final class CareStudioCanvas: ObservableObject {
    static let shared = CareStudioCanvas()

    @Published private(set) var windowSize: CGSize = CGSize(width: 1280, height: 763)
    /// True while a studio page runs a scan or a cleanup; the gradient drifts
    /// only then (CleanMyMac keeps it still on landing and result pages).
    @Published private(set) var isAnimating = false
    /// D176: whether a scan or a run has started since launch (a working page
    /// claimed the canvas). CleanMyMac folds its sidebar from then on, on
    /// every page, so the main window reads this; it is not kept across
    /// launches. (Was D141: each scanning, result and cleaning page asked for
    /// the icon rail while it was on screen, so the sidebar changed from page
    /// to page.)
    @Published private(set) var hasWorked = false

    /// The latest size reported in this pass, published on the next turn of
    /// the run loop.
    private var pendingWindowSize: CGSize?

    /// Called from the backdrops' layout callbacks. Publishing there changed
    /// the size during the view update, and while two pages overlap (a page
    /// change) or the sidebar folds, the frame changed several times in one
    /// frame — SwiftUI logged "onChange(of: CGRect) action tried to update
    /// multiple times per frame" (2.0.1 beta, D154). Reports in one pass now
    /// coalesce into one write after the update.
    func report(windowSize size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != (pendingWindowSize ?? windowSize) else { return }
        let isScheduled = pendingWindowSize != nil
        pendingWindowSize = rounded
        guard !isScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.pendingWindowSize else { return }
            self.pendingWindowSize = nil
            if size != self.windowSize { self.windowSize = size }
        }
    }

    /// What each studio page on screen asks for, in the order the pages
    /// appeared; the newest one decides. When one page replaces another,
    /// SwiftUI may show the new page before the old one disappears, and a
    /// page change can briefly show a second copy of the new page that
    /// disappears again (D141 revision, live check 2026-10-20: Smart Scan's
    /// results to Safe Cleanup's). With one owner, that copy's release
    /// cleared the chrome while the page itself stayed and kept the full
    /// sidebar; here the page's own claim applies again.
    private var claims: [(id: UUID, animating: Bool)] = []

    func claim(_ id: UUID, animating: Bool, label: String = "") {
#if DEBUG
        record("claim \(label) \(id.uuidString.prefix(4)) animating=\(animating)")
#endif
        claims.removeAll { $0.id == id }
        claims.append((id, animating))
        apply()
    }

    func release(_ id: UUID) {
#if DEBUG
        record("release \(id.uuidString.prefix(4)) newest=\(claims.last?.id == id)")
#endif
        claims.removeAll { $0.id == id }
        apply()
    }

    private func apply() {
        let newest = claims.last
        if isAnimating != (newest?.animating ?? false) { isAnimating = newest?.animating ?? false }
        if isAnimating, !hasWorked { hasWorked = true }
    }

#if DEBUG
    /// A window test that needs a launch without a scan yet starts here.
    func resetForTesting() {
        claims = []
        isAnimating = false
        hasWorked = false
    }

    /// The latest claims and releases, for a navigation test's message.
    private(set) var trace: [String] = []

    private func record(_ entry: String) {
        trace.append(entry)
        if trace.count > 40 { trace.removeFirst(trace.count - 40) }
    }
#endif
}

/// One drifting light in the module gradient.
private struct CareStudioGlow {
    let colorIndex: Int
    /// Resting centre, as a fraction of the window.
    let anchor: CGPoint
    /// Radius, as a fraction of the window's longer side.
    let radius: CGFloat
    /// How far the centre wanders while animating (fraction of the window).
    let wander: CGSize
    let phase: Double
    let opacity: Double
}

/// The full-bleed module gradient. Every column draws it in window space, so
/// the sidebar and the page meet without a seam.
struct CareStudioBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var canvas = CareStudioCanvas.shared
    /// D154: the gradient is the module's (every page of a CleanMyMac module
    /// shares one colour), so the sidebar can draw it for any page.
    let family: CareStudioFamily
    /// The detail column reports the window size; the sidebar only reads it.
    var reportsWindowSize = false
    /// D154 batch 3J: a sheet (the first-launch guide) lays the gradient out
    /// in its own frame and leaves the main window's size and drift alone.
    var fillsOwnFrame = false

    init(family: CareStudioFamily, reportsWindowSize: Bool = false, fillsOwnFrame: Bool = false) {
        self.family = family
        self.reportsWindowSize = reportsWindowSize
        self.fillsOwnFrame = fillsOwnFrame
    }

    init(module: CareStudioModule, reportsWindowSize: Bool = false) {
        self.init(family: module.family, reportsWindowSize: reportsWindowSize)
    }

    private static let glows: [CareStudioGlow] = [
        CareStudioGlow(colorIndex: 0, anchor: CGPoint(x: 0.28, y: 0.06), radius: 0.58,
                       wander: CGSize(width: 0.10, height: 0.08), phase: 0.0, opacity: 0.70),
        CareStudioGlow(colorIndex: 1, anchor: CGPoint(x: 0.60, y: 0.94), radius: 0.44,
                       wander: CGSize(width: 0.12, height: 0.06), phase: 1.9, opacity: 0.55),
        CareStudioGlow(colorIndex: 2, anchor: CGPoint(x: 0.94, y: 0.36), radius: 0.36,
                       wander: CGSize(width: 0.06, height: 0.12), phase: 3.7, opacity: 0.45)
    ]

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let window = windowSize(for: frame)
            Group {
                if canvas.isAnimating && !reduceMotion && !fillsOwnFrame {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        gradient(window: window, origin: frame.origin,
                                 time: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    gradient(window: window, origin: frame.origin, time: nil)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { report(frame) }
            .onChange(of: frame) { _, newFrame in report(newFrame) }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func windowSize(for frame: CGRect) -> CGSize {
        if reportsWindowSize || fillsOwnFrame {
            return CGSize(width: max(frame.maxX, 1), height: max(frame.maxY, 1))
        }
        return CGSize(width: max(canvas.windowSize.width, frame.maxX),
                      height: max(canvas.windowSize.height, frame.maxY))
    }

    private func report(_ frame: CGRect) {
        guard reportsWindowSize else { return }
        canvas.report(windowSize: CGSize(width: frame.maxX, height: frame.maxY))
    }

    /// Draws the window-sized gradient shifted by this column's origin.
    private func gradient(window: CGSize, origin: CGPoint, time: TimeInterval?) -> some View {
        let palette = family.palette.resolved(for: colorScheme)
        let longer = max(window.width, window.height)
        return ZStack(alignment: .topLeading) {
            // Measured CleanMyMac values: a bright top-left, the base in the
            // middle, deep towards the bottom-right (`截图/cmm-03`).
            LinearGradient(
                stops: [.init(color: CareStudioPalette.color(palette.glows[0]).opacity(0.85), location: 0),
                        .init(color: CareStudioPalette.color(palette.base), location: 0.45),
                        .init(color: CareStudioPalette.color(palette.deep), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(CareStudioPalette.color(palette.deep))
                .frame(width: window.width, height: window.height)
            ForEach(Array(Self.glows.enumerated()), id: \.offset) { _, glow in
                let center = position(of: glow, in: window, time: time)
                let colorHex = palette.glows[min(glow.colorIndex, palette.glows.count - 1)]
                RadialGradient(
                    colors: [CareStudioPalette.color(colorHex, opacity: glow.opacity),
                             CareStudioPalette.color(colorHex, opacity: 0)],
                    center: UnitPoint(x: center.x / max(window.width, 1),
                                      y: center.y / max(window.height, 1)),
                    startRadius: 0, endRadius: glow.radius * longer)
                    .frame(width: window.width, height: window.height)
            }
            // The corners stay deep, as on every CleanMyMac module.
            RadialGradient(
                colors: [.clear, CareStudioPalette.color(palette.deep, opacity: 0.55)],
                center: .center, startRadius: longer * 0.32, endRadius: longer * 0.78)
                .frame(width: window.width, height: window.height)
        }
        .offset(x: -origin.x, y: -origin.y)
        .drawingGroup()
    }

    private func position(of glow: CareStudioGlow, in window: CGSize, time: TimeInterval?) -> CGPoint {
        var x = glow.anchor.x, y = glow.anchor.y
        if let time {
            let angle = (time / CareStudioMotion.driftPeriod) * 2 * .pi + glow.phase
            x += glow.wander.width * cos(angle)
            y += glow.wander.height * sin(angle * 0.8)
        }
        return CGPoint(x: x * window.width, y: y * window.height)
    }
}

