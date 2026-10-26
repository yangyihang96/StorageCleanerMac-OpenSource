import SwiftUI

/// D-FP5: the small "i" next to a process row that explains a known system
/// process in a popover. Unknown processes show nothing. It only explains;
/// it never offers to end a process.
struct SystemProcessNoteButton: View {
    let note: SystemProcessNote
    var tint: Color = .secondary
    /// Opens the related page of this app, when the module wires one.
    var openRelated: ((SystemProcessNote.Related) -> Void)? = nil

    @State private var isShown = false

    /// Nothing for a process without a note.
    @ViewBuilder
    static func forProcess(name: String, path: String? = nil, tint: Color = .secondary,
                           openRelated: ((SystemProcessNote.Related) -> Void)? = nil) -> some View {
        if let note = SystemProcessNotes.note(forName: name, path: path) {
            SystemProcessNoteButton(note: note, tint: tint, openRelated: openRelated)
        }
    }

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .help(note.title)
        .accessibilityLabel(L10n.text("关于这个进程：\(note.title)", "About this process: \(note.title)"))
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            SystemProcessNoteCard(note: note, openRelated: openRelated.map { open in
                { related in
                    isShown = false
                    open(related)
                }
            })
            .frame(width: 330)
        }
#if DEBUG
        .layoutProbe("processNote.button")
#endif
    }
}

struct SystemProcessNoteCard: View {
    let note: SystemProcessNote
    var openRelated: ((SystemProcessNote.Related) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            section(L10n.text("这是什么", "What It Is"), note.whatItIs)
            section(L10n.text("为什么会忙", "Why It Gets Busy"), note.whyBusy)
            Label(note.settling.title, systemImage: settlingSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            section(L10n.text("可以怎么做", "What You Can Do"), note.whatToDo)
            if let related = note.related, let openRelated {
                Button(relatedTitle(related)) { openRelated(related) }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settlingSymbol: String {
        switch note.settling {
        case .finishesOnItsOwn: "hourglass"
        case .followsYourUse: "hand.point.up.left"
        case .staysRunning: "infinity"
        }
    }

    private func relatedTitle(_ related: SystemProcessNote.Related) -> String {
        switch related {
        case .extensions: L10n.text("查看扩展", "Open Extensions")
        case .maintenance: L10n.text("查看维护任务", "Open Maintenance Tasks")
        case .mobileBackups: L10n.text("查看 iOS 备份", "Open iOS Backups")
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
