import SwiftUI

/// D207 (CleanMyMac's "Add to Ignore List" on a manager's rows and the note
/// that offers to put the items back; our wording): what a manager adds to
/// the ignore list, and that note. One addition may span categories (a
/// subgroup's rules). Put Back removes exactly the entries this addition
/// made, not whatever the list added last, and then gives the manager its
/// rows back. A manager hides what the list covers at once; Settings'
/// changes reach the results with the next scan, as D207 has it.
@MainActor
final class IgnoreListFeedback: ObservableObject {
    /// Where a note shows: the main window, or the malware list's sheet.
    enum Place: Sendable {
        case window, malwareList
    }

    struct Item: Sendable {
        let target: IgnoreListTarget
        let category: IgnoreCategory
        let name: String
    }

    struct Note: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let canPutBack: Bool
        let place: Place
    }

    /// How long a note stays.
    static let visibleSeconds: Double = 8

    @Published private(set) var note: Note?
    private let list: () -> IgnoreListStore?
    private var addedEntryIDs: Set<String> = []
    private var restore: ((IgnoreListSnapshot) -> Void)?
    private var dismissal: Task<Void, Never>?

    init(list: @escaping () -> IgnoreListStore?) {
        self.list = list
    }

    /// Adds `items` as one addition and says so. Returns the list as it is
    /// afterwards, or nil when there is no list or nothing could be saved;
    /// the caller then hides the rows the list covers and hands them to
    /// `onPutBack`.
    func add(_ items: [Item], place: Place = .window) -> IgnoreListSnapshot? {
        guard let store = list(), !items.isEmpty else { return nil }
        let before = Set(store.snapshot().entries.map(\.id))
        var added = 0
        for (category, group) in Dictionary(grouping: items, by: \.category).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let names = Dictionary(group.map { ($0.target.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            added += store.add(group.map(\.target), category: category, displayNames: names)
        }
        let after = store.snapshot()
        restore = nil
        addedEntryIDs = Set(after.entries.map(\.id)).subtracting(before)
        if added > 0 {
            show(items.count == 1
                 ? L10n.text("已把“\(items[0].name)”加入忽略列表", "“\(items[0].name)” is on the Ignore List now")
                 : L10n.text("已把 \(ByteFormat.count(items.count)) 项加入忽略列表",
                             "\(ByteFormat.count(items.count)) items are on the Ignore List now"),
                 canPutBack: true, place: place)
            return after
        }
        if items.allSatisfy({ after.lists($0) }) {
            show(L10n.text("已在忽略列表里", "Already on the Ignore List"), canPutBack: false, place: place)
            return after
        }
        show(store.takeNotice() ?? L10n.text("没能加入忽略列表。", "Could not add to the Ignore List."),
             canPutBack: false, place: place)
        return nil
    }

    /// The rows the caller hid for the note on screen; after Put Back those
    /// the list no longer covers come back (`restore` gets the list as it is
    /// then).
    func onPutBack(_ restore: @escaping (IgnoreListSnapshot) -> Void) {
        guard note?.canPutBack == true else { return }
        self.restore = restore
    }

    func putBack() {
        guard let note, note.canPutBack, let store = list() else { return }
        let ids = addedEntryIDs, restore = self.restore
        addedEntryIDs = []
        self.restore = nil
        guard store.remove(ids: ids) else {
            show(store.takeNotice() ?? L10n.text("没能放回原处。", "Could not put the items back."),
                 canPutBack: false, place: note.place)
            return
        }
        dismiss()
        restore?(store.snapshot())
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        note = nil
    }

    private func show(_ text: String, canPutBack: Bool, place: Place) {
        let note = Note(text: text, canPutBack: canPutBack, place: place)
        self.note = note
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            guard !Task.isCancelled, let self, self.note?.id == note.id else { return }
            self.note = nil
        }
    }
}

private extension IgnoreListSnapshot {
    /// Whether the list has `item` itself (its path, or its app for an app category).
    func lists(_ item: IgnoreListFeedback.Item) -> Bool {
        let path = PathSafety.normalizedPath(item.target.path)
        let bundle = item.category.isApplication
            ? item.target.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return entries.contains { $0.category == item.category && $0.target.path == path && $0.target.bundleIdentifier == bundle }
    }
}

/// The managers' menu item: one row, or a group's or a selection's rows.
enum IgnoreListMenu {
    static func title(count: Int) -> String {
        count == 1
            ? L10n.text("加入忽略列表", "Add to Ignore List")
            : L10n.text("忽略 \(ByteFormat.count(count)) 项", "Add \(ByteFormat.count(count)) Items to Ignore List")
    }
}

private struct IgnoreListFeedbackKey: EnvironmentKey {
    static var defaultValue: IgnoreListFeedback? { nil }
}

extension EnvironmentValues {
    /// D207: the main window's ignore-list note (the store's), for the pages
    /// whose models do not hold the store.
    var ignoreListFeedback: IgnoreListFeedback? {
        get { self[IgnoreListFeedbackKey.self] }
        set { self[IgnoreListFeedbackKey.self] = newValue }
    }
}

/// The note after an addition: what went on the list, Put Back while it
/// shows, and a close button, on the glass capsule the app's other notes
/// use; it goes after a few seconds.
struct CareStudioIgnoreNote: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var feedback: IgnoreListFeedback
    let place: IgnoreListFeedback.Place

    var body: some View {
        ZStack {
            if let note = feedback.note, note.place == place {
                bar(note)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: feedback.note?.id)
    }

    private func bar(_ note: IgnoreListFeedback.Note) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppDesignTokens.Palette.information)
                .accessibilityHidden(true)
            Text(note.text)
                .font(.system(size: 13))
                .lineLimit(2)
            if note.canPutBack {
                Button(L10n.text("放回原处", "Put Back"), action: feedback.putBack)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppDesignTokens.Palette.accent)
                    .buttonStyle(CareStudioRowButtonStyle())
#if DEBUG
                    .layoutProbe("careStudio.ignoreNote.putBack")
#endif
            }
            Button(action: feedback.dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .accessibilityLabel(L10n.text("关闭", "Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassCapsule(tint: AppDesignTokens.Palette.information, elevated: true)
        .onChange(of: note.id, initial: true) { _, _ in
            AccessibilityNotification.Announcement(note.text).post()
        }
#if DEBUG
        .layoutProbe("careStudio.ignoreNote")
#endif
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
