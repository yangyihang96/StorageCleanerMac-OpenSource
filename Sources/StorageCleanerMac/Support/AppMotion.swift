import SwiftUI

/// UI 2.0 motion tokens (DECISIONS D53, UI-V2-SPEC §3). Every animation is
/// bound to a value; nothing here starts a repeating animation on its own.
///
/// Reduce Motion (§3.1): movement and scale become a 0.2 s fade, loops stop,
/// counters jump to their final value and sliding selections snap in place.
enum AppMotion {
    enum Token: String, CaseIterable, Sendable {
        /// Hover highlight and tooltips.
        case hover
        /// Press and release.
        case press
        /// Expand/collapse, layout class changes, sliding selections.
        case standard
        /// Page changes, results appearing, completion states.
        case emphasized
        /// Rings, curves, bars and counters.
        case data
    }

    /// What a token becomes when Reduce Motion is on (§3.1).
    enum ReducedBehavior: Equatable, Sendable {
        /// Plays as a 0.2 s opacity fade; any offset or scale is dropped.
        case fade
        /// Applies immediately.
        case immediate
    }

    static let hover = Animation.easeOut(duration: 0.16)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)
    static let standard = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let emphasized = Animation.spring(response: 0.55, dampingFraction: 0.82)
    static let data = Animation.easeInOut(duration: 0.7)
    /// The only curve used under Reduce Motion.
    static let reducedFade = Animation.easeInOut(duration: 0.2)
    /// Outgoing pages leave quickly so two pages never compete (§3.2.1).
    static let pageExit = Animation.easeOut(duration: 0.15)
    /// A page change (§3.2.1) and the Smart Scan morph (§3.2.3): the
    /// emphasized feel as a 0.5 s ease-out that ends exactly, instead of a
    /// spring whose tail keeps moving the morphing card by fractions of a
    /// point for over a second after it looks settled.
    static let pageChange = Animation.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.5)

    /// Staggered entrances only cover the first 12 items (§3.3).
    static let orbitRotationDuration: TimeInterval = 2.4
    static let staggerLimit = 12
    static let staggerStep: Double = 0.035
    /// Batch updates above this many rows are applied without animation.
    static let bulkAnimationRowLimit = 200

    static func runsOrbit(isActive: Bool, isVisible: Bool, reduceMotion: Bool) -> Bool {
        isActive && isVisible && !reduceMotion
    }

    static func animation(_ token: Token) -> Animation {
        switch token {
        case .hover: hover
        case .press: press
        case .standard: standard
        case .emphasized: emphasized
        case .data: data
        }
    }

    static func reducedBehavior(_ token: Token) -> ReducedBehavior {
        switch token {
        case .hover, .standard, .emphasized: .fade
        case .press, .data: .immediate
        }
    }

    /// The animation to run for `token`; `nil` means apply immediately.
    static func resolved(_ token: Token, reduceMotion: Bool) -> Animation? {
        guard reduceMotion else { return animation(token) }
        switch reducedBehavior(token) {
        case .fade: return reducedFade
        case .immediate: return nil
        }
    }

    /// A selection indicator slides between rows; under Reduce Motion it
    /// lands in place at once (§3.1).
    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : standard
    }

    /// Layout changes (a group expanding, a size class or header form
    /// changing, the sidebar narrowing to its rail) move content. Under
    /// Reduce Motion they land at once; rows that appear still fade
    /// (`rowTransition` carries its own fade), so nothing slides (§3.1).
    static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : standard
    }

    /// An entrance that grows from `start` to full size. Under Reduce Motion
    /// the geometry stays at rest and only the opacity changes (§3.1).
    static func entranceScale(from start: CGFloat, hasEntered: Bool, reduceMotion: Bool) -> CGFloat {
        hasEntered || reduceMotion ? 1 : start
    }

    /// Shared-geometry morphs (the Smart Scan button becoming the progress
    /// card, §3.2.3) are movement: under Reduce Motion the two views are not
    /// matched and the page change is the plain fade (§3.1).
    static func morphsGeometry(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func staggerDelay(for index: Int) -> Double {
        Double(min(max(index, 0), staggerLimit)) * staggerStep
    }

    static func participatesInStagger(_ index: Int) -> Bool {
        index >= 0 && index < staggerLimit
    }

    /// Whether an item plays its staggered entrance: one of the first 12,
    /// and not inside an update of more than 200 rows (§3.3). A group that
    /// appears when a large tier opens, or when a filter adds it, shows at
    /// once (review 2, P2-1).
    static func staggerAnimates(index: Int, scope: BulkUpdateScope?) -> Bool {
        participatesInStagger(index) && (scope?.allowsAnimation ?? true)
    }

    /// §3.3: an update touching more than 200 rows is not animated.
    static func allowsAnimation(rowCount: Int) -> Bool {
        rowCount <= bulkAnimationRowLimit
    }

    /// §3.2.1: the new page fades in and rises 8 pt; the old page fades out
    /// in 0.15 s. Reduce Motion keeps only a fade. The spec's 0.995 → 1
    /// scale is left out: a scaled page reports scaled frames to everything
    /// that measures it during the transition (a 360 pt list pane read as
    /// 358.2 pt), the reason the earlier 0.988 page scale was removed too.
    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(
                insertion: AnyTransition.opacity.animation(reducedFade),
                removal: pageRemoval.animation(reducedFade)
            )
        }
        return .asymmetric(
            insertion: AnyTransition.modifier(
                active: AppMotionPageModifier(opacity: 0, offset: 8),
                identity: AppMotionPageModifier(opacity: 1, offset: 0)
            ).animation(pageChange),
            removal: pageRemoval.animation(pageExit)
        )
    }

    /// The page on its way out fades, and from the first frame it neither
    /// takes clicks nor reaches VoiceOver: during a change only the new page
    /// can be operated or read (contract #11).
    static var pageRemoval: AnyTransition {
        AnyTransition.modifier(
            active: AppMotionOutgoingPageModifier(isLeaving: true),
            identity: AppMotionOutgoingPageModifier(isLeaving: false)
        )
    }

    /// Floating panels fade and scale 0.98 → 1 (§3.2.7).
    static func popTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.98))
    }

    /// Rows inserted or removed move and fade (§3.2.4). Under Reduce Motion
    /// the layout lands at once (`layout(reduceMotion:)`) and the rows only
    /// fade, with their own 0.2 s curve.
    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return AnyTransition.opacity.animation(reducedFade) }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .move(edge: .top))
        )
    }
}

struct AppMotionPageModifier: ViewModifier {
    let opacity: Double
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offset)
    }
}

/// The outgoing page of a page change: transparent, not hit-testable and
/// hidden from accessibility while it fades out.
struct AppMotionOutgoingPageModifier: ViewModifier {
    let isLeaving: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isLeaving ? 0 : 1)
            .allowsHitTesting(!isLeaving)
            .accessibilityHidden(isLeaving)
    }
}

/// Cards and rows appear one after another (only the first 12 move, and
/// none inside a bulk update; see `staggerAnimates`).
private struct AppStaggeredAppearanceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bulkUpdateScope) private var bulkScope
    @State private var isVisible = false

    let index: Int
    let distance: CGFloat

    func body(content: Content) -> some View {
        let animates = AppMotion.staggerAnimates(index: index, scope: bulkScope)
        content
            .opacity(isVisible || !animates ? 1 : 0)
            .offset(y: isVisible || !animates || reduceMotion ? 0 : distance)
            .onAppear {
                guard !isVisible else { return }
                guard animates else {
                    // Shown at once, and remembered as shown: a later, smaller
                    // scope or a new position must not hide it again (it keeps
                    // its identity, so it does not appear a second time).
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isVisible = true }
                    return
                }
                let animation = reduceMotion
                    ? AppMotion.reducedFade
                    : AppMotion.emphasized.delay(AppMotion.staggerDelay(for: index))
#if DEBUG
                AppMotionDebugCounters.staggeredEntrances += 1
#endif
                withAnimation(animation) { isVisible = true }
            }
    }
}

#if DEBUG
/// Counts entrance animations that actually start (tests of §3.3).
@MainActor
enum AppMotionDebugCounters {
    static var staggeredEntrances = 0
}
#endif

/// Clickable cards float 2 pt and strengthen their edge on hover; list rows
/// only highlight (§3.2.6). Reduce Motion keeps the highlight, not the lift.
private struct AppHoverLiftModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let active = isHovered && isEnabled
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(active ? 0.38 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .offset(y: active && !reduceMotion ? -2 : 0)
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: active)
            .onHover { isHovered = $0 }
    }
}

/// Counters roll through the numbers with the data curve; under Reduce Motion
/// they jump to the final value.
private struct AppDataTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(AppMotion.resolved(.data, reduceMotion: reduceMotion), value: value)
    }
}

/// §3.3: one update and all the rows it changes, added up over every group
/// it spans (a risk tier's checkbox changes the rows of all its groups at
/// once). Above 200 rows the update is applied without animation, and
/// `disablesAnimations` keeps the rows' own implicit animations (checkbox,
/// hover, data) from coming back.
struct BulkUpdateScope: Equatable, Sendable {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = max(0, rowCount)
    }

    init(rowCounts: [Int]) {
        self.init(rowCount: rowCounts.reduce(0) { $0 + max(0, $1) })
    }

    var allowsAnimation: Bool {
        AppMotion.allowsAnimation(rowCount: rowCount)
    }

    /// The transaction of the update: `animation` (nil keeps the rows'
    /// implicit animations) when small enough, otherwise none at all.
    func transaction(_ animation: Animation? = nil) -> Transaction {
        var transaction = Transaction(animation: allowsAnimation ? animation : nil)
        transaction.disablesAnimations = !allowsAnimation
        return transaction
    }

    func perform<Result>(_ animation: Animation? = nil, _ body: () throws -> Result) rethrows -> Result {
        try withTransaction(transaction(animation), body)
    }
}

/// §3.3 guard for lists: an update of more than 200 rows is not animated.
private struct AppBulkAnimationGuardModifier: ViewModifier {
    let scope: BulkUpdateScope

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if !scope.allowsAnimation {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            // Entrances below read the largest enclosing scope, so a group
            // inside a large tier never starts its own animation.
            .transformEnvironment(\.bulkUpdateScope) { current in
                if (current?.rowCount ?? -1) < scope.rowCount { current = scope }
            }
    }
}

private struct BulkUpdateScopeKey: EnvironmentKey {
    static let defaultValue: BulkUpdateScope? = nil
}

extension EnvironmentValues {
    /// The rows of the update that encloses a view (§3.3).
    var bulkUpdateScope: BulkUpdateScope? {
        get { self[BulkUpdateScopeKey.self] }
        set { self[BulkUpdateScopeKey.self] = newValue }
    }
}

extension View {
    func appStaggeredAppearance(index: Int, distance: CGFloat = 8) -> some View {
        modifier(AppStaggeredAppearanceModifier(index: index, distance: distance))
    }

    func appHoverLift(cornerRadius: CGFloat = AppDesignTokens.Corner.card, tint: Color = .white) -> some View {
        modifier(AppHoverLiftModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func appDataTransition<Value: Equatable>(value: Value) -> some View {
        modifier(AppDataTransitionModifier(value: value))
    }

    func appBulkAnimationGuard(rowCount: Int) -> some View {
        modifier(AppBulkAnimationGuardModifier(scope: BulkUpdateScope(rowCount: rowCount)))
    }

    /// The guard for a view holding several groups: their rows are added up.
    func appBulkAnimationGuard(_ scope: BulkUpdateScope) -> some View {
        modifier(AppBulkAnimationGuardModifier(scope: scope))
    }
}
