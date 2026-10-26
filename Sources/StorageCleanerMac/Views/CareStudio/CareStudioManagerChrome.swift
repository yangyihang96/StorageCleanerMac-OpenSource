import SwiftUI

/// D154: the light review panel every CleanMyMac module opens from its
/// results ("%@ Manager"): Back on the left, the title in the middle,
/// search and sort on the right; a category column, the rows, and a footer
/// that counts the selection beside the one primary action. The panel is
/// light in both appearances, as CleanMyMac's is; `CareStudioJunkManager`
/// draws the same panel for junk.
struct CareStudioManagerChrome<Categories: View, Content: View, FooterDetail: View>: View {
    let module: CareStudioModule
    let title: String
    @Binding var query: String
    var searchPrompt = L10n.text("搜索已发现的项目", "Search found items")
    var sortTitle: String? = nil
    var sortOptions: [(id: String, title: String)] = []
    var onSort: ((String) -> Void)? = nil
    var categoryWidth: CGFloat = 210
    let selectionSummary: String
    let primaryTitle: String
    var primaryEnabled = true
    let onPrimary: () -> Void
    let onBack: () -> Void
    @ViewBuilder var categories: Categories
    @ViewBuilder var content: Content
    @ViewBuilder var footerDetail: FooterDetail

    @State private var chromeID = UUID()

    var body: some View {
        ZStack {
            CareStudioBackdrop(module: module, reportsWindowSize: true)
            VStack(spacing: 0) {
                header
                Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
                HStack(spacing: 0) {
                    categories
                        .frame(width: categoryWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
                footer
            }
            .background(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous)
                .fill(CareStudioManagerInk.panel))
            .clipShape(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(CareStudioMetrics.managerInset)
            .environment(\.colorScheme, .light)
        }
        .pageOwnsScrolling()
        .onAppear { CareStudioCanvas.shared.claim(chromeID, animating: false, label: "manager.\(module.rawValue)") }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
        .onExitCommand(perform: onBack)
#if DEBUG
        .layoutProbe("careStudio.manager.\(module.rawValue)")
#endif
    }

    private var header: some View {
        CareStudioManagerHeaderLayout {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(L10n.text("返回", "Back")).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(CareStudioManagerInk.accent)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .keyboardShortcut(.cancelAction)
            CareStudioManagerTitle(title: title)
            HStack(spacing: 12) {
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
                if let sortTitle, let onSort, !sortOptions.isEmpty {
                    Menu {
                        ForEach(sortOptions, id: \.id) { option in
                            Button(option.title) { onSort(option.id) }
                        }
                    } label: {
                        // One concatenated Text: a borderless menu shows only
                        // the first view of a stacked label.
                        (Text(L10n.text("排序：", "Sort by: ")).foregroundStyle(CareStudioManagerInk.primary)
                            + Text(sortTitle).foregroundStyle(CareStudioManagerInk.accent))
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

    private var footer: some View {
        HStack(spacing: 12) {
            footerDetail
            Spacer(minLength: 8)
            Text(selectionSummary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.primary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onPrimary) {
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 30)
                    // CleanMyMac's managers use the same pink action in every module.
                    .background(Capsule(style: .continuous)
                        .fill(CareStudioManagerInk.accent.opacity(primaryEnabled ? 1 : 0.4)))
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .disabled(!primaryEnabled)
            // D213: no Return key. The action still runs on one click (D205
            // 附), but only a click starts it (10-25: a Return press removed the
            // preselected leftovers and installers).
#if DEBUG
            .layoutProbe("careStudio.manager.primary")
#endif
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }
}

extension CareStudioManagerChrome where FooterDetail == EmptyView {
    init(module: CareStudioModule, title: String, query: Binding<String>,
         searchPrompt: String = L10n.text("搜索已发现的项目", "Search found items"),
         sortTitle: String? = nil, sortOptions: [(id: String, title: String)] = [],
         onSort: ((String) -> Void)? = nil, categoryWidth: CGFloat = 210,
         selectionSummary: String, primaryTitle: String, primaryEnabled: Bool = true,
         onPrimary: @escaping () -> Void, onBack: @escaping () -> Void,
         @ViewBuilder categories: () -> Categories, @ViewBuilder content: () -> Content) {
        self.init(module: module, title: title, query: query, searchPrompt: searchPrompt, sortTitle: sortTitle,
                  sortOptions: sortOptions, onSort: onSort, categoryWidth: categoryWidth,
                  selectionSummary: selectionSummary, primaryTitle: primaryTitle, primaryEnabled: primaryEnabled,
                  onPrimary: onPrimary, onBack: onBack, categories: categories, content: content,
                  footerDetail: { EmptyView() })
    }
}

/// A manager's title in its header (one line; it truncates rather than
/// run under the controls).
struct CareStudioManagerTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(CareStudioManagerInk.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
#if DEBUG
            .layoutProbe("careStudio.manager.title")
#endif
    }
}

/// The manager header: Back at the leading edge, the controls at the
/// trailing edge, and the title centred on the panel when it clears both
/// (CleanMyMac's header). In a narrow panel the title moves into the room
/// between them, and truncates there, instead of running under the search.
struct CareStudioManagerHeaderLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing },
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let title = subviews[1].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(trailing))
        let roomMin = bounds.minX + leading.width + spacing
        let roomMax = bounds.maxX - trailing.width - spacing
        let width = max(0, min(title.width, roomMax - roomMin))
        let x = min(max(bounds.midX - width / 2, roomMin), roomMax - width)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: title.height))
    }
}

/// One category in a manager's left column: icon, name, count or size; the
/// current one on a soft tinted block (CleanMyMac's lilac selection).
struct CareStudioManagerCategoryRow: View {
    let module: CareStudioModule
    let title: String
    let systemImage: String
    var detail: String? = nil
    let isSelected: Bool
    /// D166: the category's object (CleanMyMac's coloured category icons);
    /// without it the row keeps its round symbol.
    var art: GeneratedArt? = nil
    /// A browser or app category shows the app's own icon (CleanMyMac's
    /// browser rows in the Protection manager).
    var appIconPath: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let art {
                    FeatureLightfieldArtwork(art: art, variant: .header)
                        .hueRotation(module.family.hueRotation(for: art))
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                } else if let appIconPath {
                    CachedAppIconView(path: appIconPath, size: 26) {
                        CareStudioGlyph(module: module, systemImage: systemImage, side: 24)
                    }
                } else {
                    CareStudioGlyph(module: module, systemImage: systemImage, side: 24)
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? CareStudioManagerInk.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// D166: an empty list in a manager panel — the state picture in its own
/// colours over one line (and an optional second), as CleanMyMac's empty
/// categories show a picture instead of a bare line of text.
struct CareStudioManagerEmptyState: View {
    var art: GeneratedArt = .stateEmpty
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            CareStudioFamilyMark(family: nil, art: art, side: 72)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
#if DEBUG
        .layoutProbe("careStudio.manager.empty")
#endif
    }
}
