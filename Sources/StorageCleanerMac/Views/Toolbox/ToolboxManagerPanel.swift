import AppKit
import SwiftUI

/// D-FP1–D-FP6: the review panel the new tool pages share. It is the
/// Cleanup Manager's layout (D141): a light panel over the module gradient,
/// Back, a centred title, search and sort in the header, categories on the
/// left, rows in the middle, and the selection with one main button below.
/// Colours come from the studio inks; nothing here picks its own.
struct ToolboxManagerPanel<Categories: View, Rows: View, Footer: View>: View {
    @Environment(\.careStudioReviewReturn) private var reviewReturn
    let module: CareStudioModule
    let title: String
    @Binding var query: String
    var searchPrompt = L10n.text("搜索", "Search")
    var sortOptions: [ToolboxSort] = [.size, .name]
    @Binding var sort: ToolboxSort
    var showsSearch = true
    var categoryWidth: CGFloat = 224
    let onBack: () -> Void
    @ViewBuilder let categories: Categories
    @ViewBuilder let rows: Rows
    @ViewBuilder let footer: Footer

    @State private var chromeID = UUID()
#if DEBUG
    @State private var hookID = UUID()
#endif

    /// D202: on Smart Care's Review (the maintenance tasks Performance's
    /// Review opens) Back goes back to Smart Care, not to the module's page.
    private var back: () -> Void { reviewReturn?.action ?? onBack }

    var body: some View {
        ZStack {
            CareStudioBackdrop(module: module, reportsWindowSize: true)
            VStack(spacing: 0) {
                header
                Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
                HStack(spacing: 0) {
                    categories.frame(width: categoryWidth)
                    Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1)
                    rows.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(CareStudioManagerInk.footer)
            }
            .background(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous)
                .fill(CareStudioManagerInk.panel))
            .clipShape(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(CareStudioMetrics.managerInset)
            .environment(\.colorScheme, .light)
        }
        .onAppear { CareStudioCanvas.shared.claim(chromeID, animating: false, label: "toolbox") }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
        .onExitCommand(perform: back)
#if DEBUG
        .layoutProbe("toolbox.manager")
#endif
    }

    private var header: some View {
        CareStudioManagerHeaderLayout {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(L10n.text("返回", "Back")).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(CareStudioManagerInk.accent)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(reviewReturn == nil ? L10n.text("返回", "Back")
                                                    : L10n.text("返回智能扫描", "Back to Smart Scan"))
#if DEBUG
            .onAppear { ToolboxManagerTestHook.back.register(hookID, back) }
            .onChange(of: reviewReturn == nil) { _, _ in ToolboxManagerTestHook.back.register(hookID, back) }
            .onDisappear { ToolboxManagerTestHook.back.unregister(hookID) }
#endif
            CareStudioManagerTitle(title: title)
            HStack(spacing: 12) {
                if showsSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                    TextField(searchPrompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 150)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(CareStudioManagerInk.field))
                }
                if sortOptions.count > 1 {
                    Menu {
                        ForEach(sortOptions) { option in
                            Button(option.title) { sort = option }
                        }
                    } label: {
                        // One Text: a menu label keeps only the first view of a stack.
                        (Text(L10n.text("排序：", "Sort by: ")).foregroundColor(CareStudioManagerInk.primary)
                            + Text(sort.title).foregroundColor(CareStudioManagerInk.accent))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
#if DEBUG
            .layoutProbe("careStudio.manager.controls")
#endif
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

#if DEBUG
/// What the window test presses (as `CareStudioTitleBarTestHook`): a click
/// reaches the panel only while the test app is in front. A page change can
/// show a second copy of the panel briefly (`ViewCopyHook`).
@MainActor
enum ToolboxManagerTestHook {
    static var back = ViewCopyHook<() -> Void>()
    static var pressBack: (() -> Void)? { back.current }
}
#endif

enum ToolboxSort: String, CaseIterable, Identifiable {
    case size, name, date
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: L10n.text("大小", "Size")
        case .name: L10n.text("名称", "Name")
        case .date: L10n.text("日期", "Date")
        }
    }
}

/// One category in the left column: its mark, title, count and size, and a
/// tick when it holds rows that can be chosen.
struct ToolboxCategoryRow: View {
    let module: CareStudioModule
    let title: String
    let detail: String
    let systemImage: String
    /// An app's own icon (the chat app a row belongs to); the module mark
    /// when the app is not installed.
    var appIconPath: String? = nil
    /// D166: the category's object, in the module colour.
    var art: GeneratedArt? = nil
    let isCurrent: Bool
    var tick: TriStateSelection? = nil
    var tickEnabled = true
    let onSelect: () -> Void
    var onToggle: () -> Void = {}

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if let art {
                    FeatureLightfieldArtwork(art: art, variant: .header)
                        .hueRotation(module.family.hueRotation(for: art))
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else if let appIconPath {
                    CachedAppIconView(path: appIconPath, size: 28) {
                        CareStudioGlyph(module: module, systemImage: systemImage, side: 28)
                    }
                } else {
                    CareStudioGlyph(module: module, systemImage: systemImage, side: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(CareStudioManagerInk.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let tick {
                    CareStudioTriTick(state: tick, isEnabled: tickEnabled, action: onToggle)
                        .accessibilityLabel(title)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? CareStudioManagerInk.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
#if DEBUG
        .layoutProbe("toolbox.category")
#endif
    }
}

struct ToolboxBadge: Hashable {
    enum Tone: Hashable { case accent, warning, danger, neutral }
    let text: String
    var tone: Tone = .neutral

    var color: Color {
        switch tone {
        case .accent: CareStudioManagerInk.accent
        case .warning: CareStudioManagerInk.warning
        case .danger: CareStudioManagerInk.danger
        case .neutral: CareStudioManagerInk.secondary
        }
    }
}

/// One row: tick (or a lock when it cannot be chosen here), icon, name with
/// badges, one line of detail, the value and a way into Finder.
struct ToolboxItemRow<Icon: View>: View {
    let title: String
    var badges: [ToolboxBadge] = []
    let detail: String
    var value: String = ""
    /// nil: listed only; the lock's help says why.
    var tick: TriStateSelection? = nil
    var tickEnabled = true
    var lockedReason: String? = nil
    var help: String? = nil
    var onToggle: () -> Void = {}
    var onReveal: (() -> Void)? = nil
    var copyPath: String? = nil
    @ViewBuilder let icon: Icon

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let tick {
                    CareStudioTriTick(state: tick, isEnabled: tickEnabled, action: onToggle)
                        .accessibilityLabel(title)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.secondary.opacity(0.7))
                        .frame(width: 15, height: 15)
                        .help(lockedReason ?? "")
                        .accessibilityLabel(L10n.text("只列出", "Listed only"))
                }
            }
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(badges, id: \.self) { badge in
                        Text(badge.text)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(badge.color.opacity(0.12)))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .frame(minWidth: 62, alignment: .trailing)
            }
            if let onReveal {
                Button(action: onReveal) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .help(L10n.text("在访达中显示", "Show in Finder"))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(isHovered ? Color.black.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(help ?? "")
        .contextMenu {
            if let onReveal {
                Button(L10n.text("在访达中显示", "Show in Finder"), action: onReveal)
            }
            if let copyPath {
                Button(L10n.text("复制路径", "Copy Path")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyPath, forType: .string)
                }
            }
        }
#if DEBUG
        .layoutProbe("toolbox.row")
#endif
    }
}

/// The header above a category's rows: title, explanation and actions.
struct ToolboxSectionHeader<Actions: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) { actions }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
        }
        .foregroundStyle(CareStudioManagerInk.primary)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A text button in the panel's accent colour (secondary actions).
struct ToolboxLinkButton: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CareStudioManagerInk.accent.opacity(isEnabled ? 1 : 0.4))
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .disabled(!isEnabled)
    }
}

/// The footer: what is chosen on the left, a selection menu, one button.
struct ToolboxFooter<SelectionMenu: View>: View {
    let selectedCount: Int
    var selectedBytes: Int64? = nil
    let actionTitle: String
    let actionEnabled: Bool
    let action: () -> Void
    @ViewBuilder var selectionMenu: SelectionMenu

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Text(selectedCount == 0
                     ? L10n.text("未选择项目", "No Items Selected")
                     : L10n.text("已选 \(ByteFormat.count(selectedCount)) 项", "\(ByteFormat.count(selectedCount)) Selected"))
                    .font(.system(size: 13, weight: .semibold))
                if let selectedBytes {
                    Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1, height: 14)
                    Text(ByteFormat.storageString(selectedBytes))
                        .font(.system(size: 13))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(CareStudioManagerInk.primary)
#if DEBUG
            .layoutProbe("toolbox.footer.total")
#endif
            HStack {
                selectionMenu
                Spacer()
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(CareStudioManagerInk.accent.opacity(actionEnabled ? 1 : 0.35)))
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .disabled(!actionEnabled)
#if DEBUG
                .layoutProbe("toolbox.footer.action")
#endif
            }
        }
    }
}

/// A notice above the rows: a finished operation, a conflict, a missing
/// permission.
struct ToolboxNotice: View {
    enum Tone { case info, success, warning }
    let tone: Tone
    let title: String
    var lines: [String] = []
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    /// D166: a finished operation shows its state picture (the success coin,
    /// or the warning sign when nothing or not everything was done).
    var showsStateArt = false

    private var stateArt: GeneratedArt? {
        guard showsStateArt else { return nil }
        return switch tone {
        case .info: nil
        case .success: .stateSuccess
        case .warning: .stateError
        }
    }

    private var color: Color {
        switch tone {
        case .info: CareStudioManagerInk.secondary
        case .success: CareStudioManagerInk.accent
        case .warning: CareStudioManagerInk.warning
        }
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let stateArt {
                CareStudioFamilyMark(family: nil, art: stateArt, side: 34)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lines.count > 6 {
                    Text(L10n.text("另有 \(lines.count - 6) 条", "\(lines.count - 6) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                }
                if let actionTitle, let action {
                    ToolboxLinkButton(title: actionTitle, action: action).padding(.top, 2)
                }
            }
            .foregroundStyle(CareStudioManagerInk.primary)
            Spacer(minLength: 4)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .accessibilityLabel(L10n.text("关闭", "Dismiss"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
#if DEBUG
        .layoutProbe("toolbox.notice")
#endif
    }
}

enum ToolboxText {
    static func countAndSize(_ count: Int, bytes: Int64?) -> String {
        let items = L10n.text("\(ByteFormat.count(count)) 项", count == 1 ? "1 item" : "\(ByteFormat.count(count)) items")
        guard let bytes, bytes > 0 else { return items }
        return items + " · " + ByteFormat.storageString(bytes)
    }

    static func size(_ bytes: Int64, lowerBound: Bool) -> String {
        bytes <= 0 ? "" : (lowerBound ? "≥ " : "") + ByteFormat.storageString(bytes)
    }
}

/// A borderless menu in the panel's style: "Kind: All ⌄".
struct ToolboxFilterMenu<Items: View>: View {
    let title: String
    let valueTitle: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            (Text(title).foregroundColor(CareStudioManagerInk.primary)
                + Text(valueTitle).foregroundColor(CareStudioManagerInk.accent))
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
