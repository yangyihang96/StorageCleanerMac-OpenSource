import SwiftUI

/// CleanMyMac's popover before an update it cannot run itself
/// (`popover_update_app_manually_text` / `_button`,
/// `popover_update_mas_app_manually_text`): why, then one Open button that
/// goes to where the update happens. Open runs the action the button ran
/// before; nothing is updated from here.
struct ManualUpdateExplanation: View {
    enum Reason: Equatable {
        /// The app updates itself (its own updater).
        case application
        /// Only the App Store can update it.
        case appStore

        var text: String {
            switch self {
            // D154: our own wording (D123/D141 keep CleanMyMac's sentences out).
            case .application:
                L10n.text("这个应用自己负责更新，存储清理助手没法替它安装。打开它，用它自带的“检查更新”。",
                          "This app updates itself, so Storage Cleaner can't install the update for it. Open the app and use its own Check for Updates.")
            case .appStore:
                L10n.text("这个应用只能从 App Store 更新。打开 App Store 的“更新”安装。",
                          "This app can only be updated from the App Store. Open Updates in the App Store to install it.")
            }
        }
    }

    let reason: Reason
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reason.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("打开", "Open"), action: open)
                    .keyboardShortcut(.defaultAction)
                    .appButtonChrome(.primary)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

extension View {
    /// Shows the explanation while `shown` is `reason`; Open closes it first.
    func manualUpdateExplanation(_ shown: Binding<ManualUpdateExplanation.Reason?>,
                                 for reason: ManualUpdateExplanation.Reason,
                                 open: @escaping () -> Void) -> some View {
        popover(isPresented: Binding(get: { shown.wrappedValue == reason },
                                     set: { if !$0 { shown.wrappedValue = nil } }),
                arrowEdge: .bottom) {
            ManualUpdateExplanation(reason: reason) {
                shown.wrappedValue = nil
                open()
            }
        }
    }
}
