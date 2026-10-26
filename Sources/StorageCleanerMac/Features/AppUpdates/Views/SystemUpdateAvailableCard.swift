import AppKit
import SwiftUI

/// macOS updates the system's own Software Update has already found
/// (CleanMyMac `SystemUpdateScanTask` / tile “macOS Updates Are Available”).
/// CleanMyMac asks its server; here the system's last check is read from
/// `com.apple.SoftwareUpdate` (world-readable), and installing stays with
/// System Settings, as CleanMyMac's popover says.
struct SystemSoftwareUpdate: Identifiable, Hashable, Sendable {
    let identifier: String
    let name: String
    let version: String
    var id: String { identifier.isEmpty ? name + version : identifier }
}

enum SystemSoftwareUpdateStatus {
    static let preferencesURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!

    static func recommendedUpdates(plistURL: URL = preferencesURL) -> [SystemSoftwareUpdate] {
        guard let values = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let updates = values["RecommendedUpdates"] as? [[String: Any]] else { return [] }
        return updates.compactMap { update in
            let name = (update["Display Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty else { return nil }
            return SystemSoftwareUpdate(identifier: (update["Identifier"] as? String) ?? (update["Product Key"] as? String) ?? "",
                                        name: name, version: (update["Display Version"] as? String) ?? "")
        }
    }
}

struct SystemUpdateAvailableCard: View {
    @State private var updates: [SystemSoftwareUpdate] = []
    @State private var showsDetail = false

    var body: some View {
        Group {
            if !updates.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(FeatureLightfieldPalette.accent(.updater))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("有 macOS 的可用更新", "macOS Updates Are Available"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L10n.text("让操作系统得到及时更新，以获取最新功能和安全改进。",
                                       "Keep your operating system updated with the latest features and security improvements."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(updates.map { $0.version.isEmpty ? $0.name : "\($0.name) \($0.version)" }.joined(separator: "、"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(L10n.text("查看更新", "View Update")) { showsDetail = true }
                        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("此项目应使用“系统设置”中的“系统软件更新”功能来进行更新。",
                                               "This item should be updated using system Software Update feature available in System Settings."))
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(L10n.text("前往“系统设置”", "Go to System Settings")) {
                                    showsDetail = false
                                    NSWorkspace.shared.open(SystemSoftwareUpdateStatus.settingsURL)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(14)
                            .frame(width: 300)
                        }
                }
                .padding(12)
                .background(FeatureLightfieldPalette.accent(.updater).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
                .padding(.top, AppDesignTokens.Spacing.compact)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task {
            let found = await Task.detached(priority: .utility) { SystemSoftwareUpdateStatus.recommendedUpdates() }.value
            withAnimation(.easeOut(duration: 0.25)) { updates = found }
        }
    }
}
