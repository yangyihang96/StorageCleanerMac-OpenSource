import SwiftUI

/// Report §4 item 12 (CleanMyMac 1:1, `cmm/14`, `19`, `20`, `24`): what a
/// studio page puts in the window's title bar — nothing on a landing page,
/// the module's name while it works, and on its results the name with
/// "Start Over" on the left, which asks first and then goes back to the
/// module's landing page. The page draws the two itself in the title bar's
/// band (`CareStudioTitleBarRow`), on the module's gradient beside the
/// window buttons.
enum CareStudioTitleBar {
    case hidden
    case title
    case startOver(CareStudioStartOver)
}

/// D202: on a page Smart Care's Review opened, the title bar's left button
/// goes back to Smart Care instead of starting over (the result is Smart
/// Care's, not this page's to clear).
struct CareStudioReviewReturn {
    let action: () -> Void
}

private struct CareStudioReviewReturnKey: EnvironmentKey {
    static var defaultValue: CareStudioReviewReturn? { nil }
}

extension EnvironmentValues {
    var careStudioReviewReturn: CareStudioReviewReturn? {
        get { self[CareStudioReviewReturnKey.self] }
        set { self[CareStudioReviewReturnKey.self] = newValue }
    }
}

extension View {
    /// D202: Back to Smart Care on a page Smart Care's Review opens that is
    /// no studio results page (the App Updates page). See
    /// `CareStudioReviewBack`.
    func careStudioReviewBack(_ module: CareStudioModule) -> some View {
        modifier(CareStudioReviewBack(module: module))
    }
}

/// D202: "‹ Smart Scan" where a studio results page puts it — in the window's
/// title bar band, on the left — for a page whose own frames are no studio
/// results page: the App Updates page's result is a Lightfield page and its
/// manager its own (13th build, LCU). The page's own frames leave theirs out,
/// so there is one Back. Without the band (full screen) the row takes room of
/// its own at the top, as on a studio page.
private struct CareStudioReviewBack: ViewModifier {
    @Environment(\.careStudioReviewReturn) private var reviewReturn
    let module: CareStudioModule
    @State private var band: CGFloat = 0

    func body(content: Content) -> some View {
        let inBand = band >= CareStudioTitleBarRow.minimumHeight
        content
            .environment(\.careStudioReviewReturn, nil)
            .padding(.top, reviewReturn != nil && !inBand ? CareStudioTitleBarRow.minimumHeight : 0)
            .onGeometryChange(for: CGFloat.self) { max(0, $0.frame(in: .global).minY) } action: { band = $0 }
            .overlay(alignment: .top) {
                if let reviewReturn {
                    CareStudioTitleBarRow(module: module, showsTitle: false, startOver: nil,
                                          onStartOver: {}, back: reviewReturn)
                        .frame(height: inBand ? band : CareStudioTitleBarRow.minimumHeight)
                        .offset(y: inBand ? -band : 0)
                }
            }
    }
}

/// A results page's Start Over. It is off while exclusive work that changes
/// something runs (a cleanup, an uninstall, app updates, a cache purge: the
/// heavy-work lease) and while `isEnabled` is false, and is checked again on
/// confirming.
struct CareStudioStartOver {
    var activity: HeavyWorkActivityStore?
    var isEnabled = true
    let action: () -> Void

    /// Whether the lease held now keeps Start Over off.
    @MainActor
    var isHeldByLease: Bool { activity?.activeOwner?.holdsStartOver == true }
}

extension HeavyWorkCoordinator.Owner {
    /// Item 12: work that changes files or settings holds Start Over. Reads
    /// and measurements do not: a results page's own background check (D184
    /// reads the apps for App Thinning when the Cleanup results appear) ends
    /// with the page, and a scan or test elsewhere does not touch it.
    var holdsStartOver: Bool {
        switch self {
        case .mainScan, .largeFilesScan, .duplicateScan, .networkTest, .benchmark: false
        case .cleanup, .restore, .emptyTrash, .memoryOptimization, .appUpdates, .cloudLocalCopy: true
        }
    }
}

/// The frame every studio page shares: the module gradient, the content
/// above the round button, and the small note in the bottom corner where
/// CleanMyMac prints "by MacPaw" (we print the safety promise there).
struct CareStudioPageFrame<Content: View, Action: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.careStudioReviewReturn) private var reviewReturn
    let module: CareStudioModule
    var isWorking = false
    /// Item 12: a working page shows the module's name unless it says otherwise.
    var titleBar: CareStudioTitleBar = .hidden
    var footnote: String? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action
    @State private var chromeID = UUID()
    @State private var confirmsStartOver = false

    var body: some View {
        // Item 12 (D94): the page draws its title bar row itself in the room
        // above it in its window — the window's title bar band, as the window
        // has full-size content; no page gives the window a toolbar item, so
        // the window buttons and the sidebar keep one place on every page.
        // Without that room (full screen, off screen) the row takes room of
        // its own at the top of the page. (The safe area is not read: inside
        // the split view it is already spent, 0 here.)
        GeometryReader { proxy in
            let band = max(0, proxy.frame(in: .global).minY)
            let inBand = band >= CareStudioTitleBarRow.minimumHeight
            ZStack(alignment: .bottom) {
                CareStudioBackdrop(module: module, reportsWindowSize: true)
                content
                    .padding(.top, showsTitleBarRow && !inBand ? CareStudioTitleBarRow.minimumHeight : 0)
                    .padding(.bottom, CareStudioMetrics.actionBand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                action
                    .padding(.bottom, CareStudioMetrics.actionBottomInset)
                if let footnote, !footnote.isEmpty {
                    GeometryReader { proxy in
                        // The safety line keeps to the right of the round button;
                        // a narrow window wraps it instead of running it under.
                        let room = max(120, proxy.size.width / 2 - CareStudioMetrics.actionDiameter / 2
                                       - CareStudioMetrics.actionRingGap - CareStudioMetrics.actionRingWidth - 40)
                        Label(footnote, systemImage: "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CareStudioInk.tertiary)
                            .labelStyle(.titleAndIcon)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
#if DEBUG
                            .layoutProbe("careStudio.footnote")
#endif
                            .frame(maxWidth: room, alignment: .trailing)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.trailing, 20)
                            .padding(.bottom, 16)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if showsTitleBarRow {
                    CareStudioTitleBarRow(module: module, showsTitle: showsTitle, startOver: startOver,
                                          onStartOver: { confirmsStartOver = true }, back: back)
                        .frame(height: inBand ? band : CareStudioTitleBarRow.minimumHeight)
                        .offset(y: inBand ? -band : 0)
                }
            }
        }
        .environment(\.careStudioSurface, true)
        // A studio page fits the window itself (its text scrolls in place),
        // so the round button stays in the window at every size (D77).
        .pageOwnsScrolling()
        .confirmationDialog(L10n.text("重新开始？", "Start Over?"), isPresented: $confirmsStartOver,
                            titleVisibility: .visible) {
            Button(L10n.text("重新开始", "Start Over")) {
                // The work may have started while the question was open.
                guard let startOver, startOver.isEnabled, !startOver.isHeldByLease else { return }
                startOver.action()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("回到首页，本次结果不保留；需要重新扫描才能再看到这些项目。",
                           "Goes back to the start. These results are not kept; scan again to see these items."))
        }
        .onAppear { applyChrome() }
        .onChange(of: isWorking) { _, _ in applyChrome() }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
#if DEBUG
        .layoutProbe("careStudio.page.\(module.rawValue)")
#endif
    }

    private func applyChrome() {
        CareStudioCanvas.shared.claim(chromeID, animating: isWorking, label: module.rawValue)
    }

    private var showsTitle: Bool {
        switch titleBar {
        case .hidden: isWorking
        case .title, .startOver: true
        }
    }

    private var startOver: CareStudioStartOver? {
        guard reviewReturn == nil else { return nil }
        if case let .startOver(startOver) = titleBar { return startOver } else { return nil }
    }

    /// D202: where Start Over would be, on a page Smart Care's Review opened.
    private var back: CareStudioReviewReturn? {
        guard case .startOver = titleBar else { return nil }
        return reviewReturn
    }

    private var showsTitleBarRow: Bool { showsTitle || startOver != nil || back != nil }
}

/// Item 12 (D94): the title bar row a studio page draws itself — the
/// module's name in the middle and Start Over on the left, with no plate,
/// on the module's gradient. It sits in the window's title bar band beside
/// the window buttons: the window has full-size content and a see-through
/// title bar, and no page adds a toolbar item (on 10-23 a toolbar item on
/// the results pages moved the window buttons and the sidebar 10 pt, r35).
struct CareStudioTitleBarRow: View {
    let module: CareStudioModule
    let showsTitle: Bool
    let startOver: CareStudioStartOver?
    let onStartOver: () -> Void
    /// D202: Back to Smart Care in Start Over's place.
    var back: CareStudioReviewReturn? = nil

    /// The row's height where the window has no title bar (full screen).
    static let minimumHeight: CGFloat = 28

    var body: some View {
        ZStack {
            if showsTitle {
                // The sidebar row's name (`cmm/20`: "Cleanup" on the junk
                // results), not the page's own title such as "Safe Cleanup".
                Text(module.family.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioInk.secondary)
                    .lineLimit(1)
                    // The name leaves the band free to drag the window.
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("careStudio.titleBar.title")
#if DEBUG
                    .layoutProbe("careStudio.titleBar.title")
#endif
            }
            if let startOver {
                CareStudioStartOverButton(activity: startOver.activity, isEnabled: startOver.isEnabled,
                                          action: onStartOver)
#if DEBUG
                    .layoutProbe("careStudio.titleBar.startOver")
#endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CareStudioMetrics.pageInset)
            } else if let back {
                CareStudioBackButton(action: back.action)
#if DEBUG
                    .layoutProbe("careStudio.titleBar.back")
#endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CareStudioMetrics.pageInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// D202: "‹ Smart Scan" back to Smart Care's results, in Start Over's place
/// and look.
private struct CareStudioBackButton: View {
    let action: () -> Void
#if DEBUG
    @State private var hookID = UUID()
#endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(CareStudioFamily.smartCare.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(CareStudioInk.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .help(L10n.text("回到智能扫描的结果", "Back to Smart Scan's results"))
        .accessibilityLabel(L10n.text("返回智能扫描", "Back to Smart Scan"))
        .accessibilityIdentifier("careStudio.titleBar.back")
#if DEBUG
        .onAppear { CareStudioTitleBarTestHook.back.register(hookID, action) }
        .onDisappear { CareStudioTitleBarTestHook.back.unregister(hookID) }
#endif
    }
}

private struct CareStudioStartOverButton: View {
    let activity: HeavyWorkActivityStore?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        if let activity {
            Observing(activity: activity, isEnabled: isEnabled, action: action)
        } else {
            TitleButton(isEnabled: isEnabled, action: action)
        }
    }

    /// Follows the heavy-work lease, so the button greys out while work that
    /// holds Start Over runs.
    private struct Observing: View {
        @ObservedObject var activity: HeavyWorkActivityStore
        let isEnabled: Bool
        let action: () -> Void

        var body: some View {
            TitleButton(isEnabled: isEnabled && activity.activeOwner?.holdsStartOver != true, action: action)
        }
    }

    private struct TitleButton: View {
        let isEnabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(L10n.text("重新开始", "Start Over"), systemImage: "arrow.counterclockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CareStudioInk.primary)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .help(L10n.text("回到这个模块的首页，本次结果不保留", "Go back to this module's start; these results are not kept"))
            .accessibilityIdentifier("careStudio.titleBar.startOver")
#if DEBUG
            .onAppear { CareStudioTitleBarTestHook.register(isEnabled: isEnabled, action: action) }
            .onChange(of: isEnabled) { _, enabled in CareStudioTitleBarTestHook.register(isEnabled: enabled, action: action) }
            .onDisappear { CareStudioTitleBarTestHook.pressStartOver = nil }
#endif
        }
    }
}

#if DEBUG
/// Item 12: what the window test presses. A click reaches the title bar row
/// only while the test app is in front, which a test on the user's desktop
/// cannot ask for, so the test runs the button's own action, and only while
/// the button is enabled; it checks separately that a click at the button
/// lands in the page, not in the window's title bar.
@MainActor
enum CareStudioTitleBarTestHook {
    /// Returns whether the button was enabled (and its action ran).
    static var pressStartOver: (() -> Bool)?
    /// D202: Back to Smart Scan, on a page Smart Care's Review opened.
    static var back = ViewCopyHook<() -> Void>()
    static var pressBack: (() -> Void)? { back.current }

    static func register(isEnabled: Bool, action: @escaping () -> Void) {
        pressStartOver = {
            guard isEnabled else { return false }
            action()
            return true
        }
    }
}

/// A test hook that several copies of one view may hold at once. While one
/// page replaces another, SwiftUI may show the new page before the old one
/// goes and briefly a second copy of the new page that disappears again (as
/// `CareStudioCanvas`'s claims record), so the newest copy still on screen
/// answers. With one owner that copy's disappearance cleared the hook while
/// the page stayed (r46: Smart Scan to the maintenance tasks).
struct ViewCopyHook<Action> {
    private var copies: [(id: UUID, action: Action)] = []

    var current: Action? { copies.last?.action }

    mutating func register(_ id: UUID, _ action: Action) {
        copies.removeAll { $0.id == id }
        copies.append((id, action))
    }

    mutating func unregister(_ id: UUID) {
        copies.removeAll { $0.id == id }
    }
}
#endif

/// Landing page: picture on the left, title, subtitle and list on the right,
/// round button at the bottom (CleanMyMac Smart Care / Cleanup /
/// Performance landing, `截图/cmm-01`, `cmm-03`, `cmm-14`).
struct CareStudioLandingPage<Accessory: View>: View {
    let module: CareStudioModule
    /// D166: a page that cannot start yet shows a state picture (the lock
    /// when it needs access) in place of the module's.
    var art: GeneratedArt? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var bullets: [CareStudioBullet] = []
    var status: String? = nil
    var footnote: String? = nil
    let actionTitle: String
    var actionEnabled = true
    var actionHint: String? = nil
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        CareStudioPageFrame(module: module, footnote: footnote) {
            GeometryReader { proxy in
                let wide = proxy.size.width >= 760
                let short = proxy.size.height < 430
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: max(28, min(56, proxy.size.width * 0.05))) {
                            CareStudioArt(module: module, side: artSide(proxy.size, wide: true), art: art, entrance: true)
                            fittingTextColumn(compact: short)
                                .frame(maxWidth: 440, maxHeight: proxy.size.height, alignment: .leading)
                        }
                    } else {
                        // D154: a short narrow window leaves the picture out
                        // so the text stays in the window above the button.
                        VStack(spacing: 18) {
                            if proxy.size.height >= 400 {
                                CareStudioArt(module: module, side: artSide(proxy.size, wide: false), art: art, entrance: true)
                            }
                            fittingTextColumn(compact: true)
                                .frame(maxWidth: 440, alignment: .leading)
                        }
                        .frame(maxHeight: proxy.size.height)
                    }
                }
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } action: {
            CareStudioActionButton(module: module, title: actionTitle,
                                   accessibilityHint: actionHint, action: action)
                .disabled(!actionEnabled)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// D154: when the text is taller than the page (the smallest windows),
    /// it scrolls in place instead of pushing the page past the window.
    private func fittingTextColumn(compact: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            textColumn(compact: compact)
            ScrollView(.vertical) { textColumn(compact: compact).padding(.vertical, 4) }
        }
    }

    private func textColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            CareStudioHeadline(module: module, title: title, subtitle: subtitle,
                               bullets: bullets, status: status, compact: compact)
            accessory
        }
    }

    private func artSide(_ size: CGSize, wide: Bool) -> CGFloat {
        let byHeight = size.height * (wide ? 0.62 : 0.34)
        let byWidth = wide ? size.width * 0.34 : size.width * 0.5
        return max(120, min(CareStudioMetrics.landingArtSide, byHeight, byWidth))
    }
}

extension CareStudioLandingPage where Accessory == EmptyView {
    init(module: CareStudioModule, art: GeneratedArt? = nil, title: String? = nil, subtitle: String? = nil,
         bullets: [CareStudioBullet] = [], status: String? = nil, footnote: String? = nil,
         actionTitle: String, actionEnabled: Bool = true, actionHint: String? = nil,
         action: @escaping () -> Void) {
        self.init(module: module, art: art, title: title, subtitle: subtitle, bullets: bullets,
                  status: status, footnote: footnote, actionTitle: actionTitle,
                  actionEnabled: actionEnabled, actionHint: actionHint, action: action) { EmptyView() }
    }
}

/// One category line under the running title (CleanMyMac only shows the
/// current path; Tencent Lemon and PureMac list each category as it
/// finishes — we show both).
struct CareStudioLiveCategory: Identifiable, Equatable {
    enum State: Equatable { case pending, working, found, clean, failed }
    let id: String
    let title: String
    let systemImage: String
    let state: State
    let bytes: Int64
}

/// Running page: the picture floats above the title, the current path
/// below it, the categories as they finish, and Stop with a progress ring
/// (`截图/cmm-04`, `cmm-05`; Lemon `lemon-02`).
struct CareStudioRunningPage: View {
    let module: CareStudioModule
    var title: String? = nil
    var detail: String? = nil
    var categories: [CareStudioLiveCategory] = []
    var headlineValue: String? = nil
    var progress: CareStudioActionButton.Progress = .indeterminate
    var actionTitle = L10n.text("停止", "Stop")
    var canStop = true
    var footnote: String? = nil
    /// Extra content under the categories (the cleanup stages).
    var accessory: AnyView? = nil
    var accessoryMaxWidth: CGFloat = 390
    /// A page with a task list keeps the picture small, as CleanMyMac's
    /// cleaning page does.
    var artFraction: CGFloat = 0.42
    var artMaxSide: CGFloat = CareStudioMetrics.runningArtSide
    /// CleanMyMac asks before it stops a scan or a cleanup ("继续扫描" /
    /// "停止", `分报告/cleanmymac.md` §5); nil stops at once.
    var stopConfirmation: CareStudioStopConfirmation? = nil
    let onStop: () -> Void

    @State private var confirmsStop = false

    var body: some View {
        page
            .confirmationDialog(stopConfirmation?.title ?? "", isPresented: $confirmsStop,
                                titleVisibility: .visible) {
                if let stopConfirmation {
                    Button(stopConfirmation.continueTitle, role: .cancel) {}
                    Button(stopConfirmation.stopTitle, role: .destructive, action: onStop)
                }
            } message: {
                if let message = stopConfirmation?.message { Text(message) }
            }
    }

    private func requestStop() {
        if stopConfirmation == nil { onStop() } else { confirmsStop = true }
    }

    private var page: some View {
        CareStudioPageFrame(module: module, isWorking: true, footnote: footnote) {
            GeometryReader { proxy in
                let artSide = max(96, min(artMaxSide, proxy.size.height * artFraction))
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    CareStudioArt(module: module, side: artSide, isWorking: true)
                    Text(title ?? module.scanningTitle)
                        .font(.system(size: CareStudioMetrics.runningTitleSize, weight: .regular))
                        .foregroundStyle(CareStudioInk.primary)
                        .lineLimit(1)
                        .padding(.top, 18)
                        .accessibilityAddTraits(.isHeader)
#if DEBUG
                        .layoutProbe("careStudio.running.title")
#endif
                    if let headlineValue {
                        Text(headlineValue)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CareStudioInk.primary)
                            .monospacedDigit()
                            .padding(.top, 6)
                            .contentTransition(.numericText())
                    }
                    Text(detail ?? module.scanningSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(CareStudioInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(680, proxy.size.width - 48))
                        .padding(.top, 8)
                        .help(detail ?? "")
#if DEBUG
                        .layoutProbe("careStudio.running.detail")
#endif
                    if !categories.isEmpty, proxy.size.height >= 420 {
                        CareStudioCategoryStrip(categories: categories)
                            .frame(maxWidth: min(760, proxy.size.width - 48))
                            .padding(.top, 20)
                    }
                    if let accessory, proxy.size.height >= 520 {
                        accessory
                            .frame(maxWidth: min(accessoryMaxWidth, proxy.size.width - 48))
                            .padding(.top, 16)
                    }
                    Spacer(minLength: 8)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } action: {
            CareStudioActionButton(module: module, title: actionTitle, progress: progress, action: requestStop)
                .disabled(!canStop)
        }
    }
}

/// The question CleanMyMac asks before stopping a running module.
struct CareStudioStopConfirmation {
    let title: String
    var message: String? = nil
    let continueTitle: String
    var stopTitle = L10n.text("停止", "Stop")

    static let scan = CareStudioStopConfirmation(
        title: L10n.text("停止扫描？", "Stop Scanning?"),
        message: L10n.text("已找到的结果不会保留，之后需要重新扫描。", "Results found so far are not kept; you will need to scan again."),
        continueTitle: L10n.text("继续扫描", "Continue Scanning"))

    static let cleanup = CareStudioStopConfirmation(
        title: L10n.text("停止清理？", "Stop Cleaning?"),
        message: L10n.text("当前项目处理完后停止；已移到废纸篓的项目留在废纸篓，可以恢复。",
                           "Stops after the current item; items already in the Trash stay there and can be restored."),
        continueTitle: L10n.text("继续运行", "Continue Running"))
}

/// Categories as wrapped capsules: a spinner while one is being read, a
/// tick when it is done, its size once something was found.
struct CareStudioCategoryStrip: View {
    let categories: [CareStudioLiveCategory]

    var body: some View {
        CareStudioFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(categories) { category in
                HStack(spacing: 6) {
                    stateMark(category.state)
                    Text(category.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if category.bytes > 0 {
                        Text(ByteFormat.storageString(category.bytes))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CareStudioInk.secondary)
                    } else if category.state == .clean {
                        Text(L10n.text("很干净", "Clean"))
                            .font(.system(size: 12))
                            .foregroundStyle(CareStudioInk.secondary)
                    }
                }
                .foregroundStyle(category.state == .pending ? CareStudioInk.tertiary : CareStudioInk.primary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(category.state == .working ? CareStudioInk.pillFill : CareStudioInk.tileFill))
                .overlay(Capsule(style: .continuous).strokeBorder(CareStudioInk.hairline, lineWidth: 0.8))
                .accessibilityElement(children: .combine)
            }
        }
#if DEBUG
        .layoutProbe("careStudio.running.categories")
#endif
    }

    @ViewBuilder
    private func stateMark(_ state: CareStudioLiveCategory.State) -> some View {
        switch state {
        case .pending:
            Circle().fill(CareStudioInk.tertiary).frame(width: 5, height: 5)
        case .working:
            CareStudioSpinningArc(diameter: 11, lineWidth: 1.6)
        case .found, .clean:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
        }
    }
}

/// A simple wrapping row layout, centred per line.
struct CareStudioFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let lines = arrange(subviews: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let usedWidth = lines.map(\.width).max() ?? 0
        return CGSize(width: min(width, usedWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
