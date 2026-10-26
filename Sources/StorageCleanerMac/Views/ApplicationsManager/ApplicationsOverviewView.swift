import AppKit
import SwiftUI

/// CleanMyMac's Applications scan results: “We’ve found N apps on your Mac.”
/// and one tile per finding, each with its action and Review, then “Manage My
/// Applications”. Tiles still loading show CleanMyMac's background-scan text.
struct ApplicationsOverviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ApplicationsManagerModel
    @ObservedObject var store: ScanStore
    @State private var systemUpdates: [SystemSoftwareUpdate] = []
    @State private var appeared = false

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 14)]

    var body: some View {
        // Inside the page's shared results viewport, which scrolls it.
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("我们在您的 Mac 上找到了 \(ByteFormat.count(model.entries.count)) 个应用程序。", "We’ve found \(ByteFormat.count(model.entries.count)) apps on your Mac."))
                .font(.system(size: 17, weight: .semibold))
            if model.ignoredTotal > 0 {
                Text(model.ignoredSummary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                if let updates = availableUpdateCount, updates > 0 {
                    tile(icon: "arrow.triangle.2.circlepath", tint: FeatureLightfieldPalette.accent(.updater),
                         title: L10n.text("\(ByteFormat.count(updates)) 个应用程序更新可用", "\(ByteFormat.count(updates)) Application Update\(updates == 1 ? "" : "s") Available"),
                         detail: L10n.text("更新您的软件，以获得最新的功能和兼容性改进。", "Update your software to keep up with the latest features and compatibility improvements."),
                         primary: (L10n.text("更新", "Update"), { store.showFilter(.updater) }), review: nil)
                }
                if !model.unusedEntries.isEmpty {
                    tile(icon: "hourglass", tint: FeatureLightfieldPalette.accent(.uninstall),
                         title: L10n.text("发现 \(ByteFormat.count(model.unusedEntries.count)) 个未使用的应用程序", "\(ByteFormat.count(model.unusedEntries.count)) Unused Application\(model.unusedEntries.count == 1 ? "" : "s") Found"),
                         detail: L10n.text("这些应用程序您或许早已不再使用，却持续占用着 Mac 的存储空间。", "You may not need these apps, but they take up space on your Mac."),
                         primary: (L10n.text("卸载", "Uninstall"), { model.runTile(.unused) }), review: .unused)
                }
                if model.isScanningLeftovers {
                    loadingTile
                } else if !model.leftovers.isEmpty {
                    tile(icon: "sparkles", tint: FeatureLightfieldPalette.accent(.duplicates),
                         title: L10n.text("发现 \(ByteFormat.storageString(model.leftoverBytes)) 应用程序残留文件", "\(ByteFormat.storageString(model.leftoverBytes)) of App Leftovers Found"),
                         detail: L10n.text("删除已卸载应用程序在系统中留下的残余项目。", "Remove the bits that remained on your system from previously uninstalled applications."),
                         primary: (L10n.text("移除", "Remove"), { model.runTile(.leftovers) }), review: .leftovers)
                }
                if !model.installers.isEmpty {
                    tile(icon: "shippingbox", tint: AppDesignTokens.Palette.warning,
                         title: L10n.text("已发现 \(ByteFormat.storageString(model.installerBytes)) 的安装文件", "\(ByteFormat.storageString(model.installerBytes)) of Installation Files Found"),
                         detail: L10n.text("如果您不再需要相关的 DMG 文件或其他应用程序的安装程序，请删除这些安装文件。", "Remove DMG files or other application installers if you no longer need them."),
                         primary: (L10n.text("移除", "Remove"), { model.runTile(.installers) }), review: .installers)
                }
                if !model.thirtyTwoBitEntries.isEmpty {
                    tile(icon: "exclamationmark.triangle", tint: AppDesignTokens.Palette.destructive,
                         title: L10n.text("发现 \(ByteFormat.count(model.thirtyTwoBitEntries.count)) 个不受支持的应用程序", "\(ByteFormat.count(model.thirtyTwoBitEntries.count)) Unsupported Application\(model.thirtyTwoBitEntries.count == 1 ? "" : "s") Found"),
                         detail: L10n.text("旧的 32 位版本应用程序无法在您的操作系统上运行。卸载它们可以释放存储空间。", "Old 32-bit applications cannot work on your OS. Uninstall them to free up space."),
                         primary: (L10n.text("卸载", "Uninstall"), { model.runTile(.thirtyTwoBit) }), review: .thirtyTwoBit)
                }
                if !systemUpdates.isEmpty {
                    tile(icon: "gearshape.arrow.triangle.2.circlepath", tint: AppDesignTokens.Palette.information,
                         title: L10n.text("有 macOS 的可用更新", "macOS Updates Are Available"),
                         detail: L10n.text("让操作系统得到及时更新，以获取最新功能和安全改进。", "Keep your operating system updated with the latest features and security improvements."),
                         primary: (L10n.text("查看更新", "View Update"), { NSWorkspace.shared.open(SystemSoftwareUpdateStatus.settingsURL) }),
                         review: nil)
                }
                tile(icon: "square.grid.2x2", tint: FeatureLightfieldPalette.accent(.uninstall),
                     title: L10n.text("建议卸载掉不常用的应用程序", "Consider removing some applications"),
                     detail: L10n.text("检查不再需要的软件，完整卸载掉以释放磁盘存储空间。", "Review applications you no longer need and remove them completely to free up space."),
                     primary: nil, review: .all)
            }
            HStack {
                Spacer()
                Button(L10n.text("管理我的应用程序", "Manage My Applications")) { model.review(.all) }
                    .appButtonChrome(.primary)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 16)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .task {
            if let animation = FeatureLightfieldMotion.animation(FeatureLightfieldMotion.layerMove, reduceMotion: reduceMotion) {
                withAnimation(animation) { appeared = true }
            } else {
                appeared = true
            }
            systemUpdates = await Task.detached(priority: .utility) { SystemSoftwareUpdateStatus.recommendedUpdates() }.value
        }
    }

    /// Updates the updater's last scan found (CleanMyMac tile
    /// “%d Application Updates Available”).
    /// D190: the same count as the Care Studio tile and Smart Care.
    private var availableUpdateCount: Int? { store.availableAppUpdateCount }

    private var loadingTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在查找应用程序残留文件……", "Looking for App Leftovers..."))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(L10n.text("正在后台扫描之前卸载软件遗留的各类文件，该过程可能需要片刻。",
                           "Looking for files left behind by previously uninstalled applications in the background. This may take a moment."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tile(icon: String, tint: Color, title: String, detail: String,
                      primary: (String, () -> Void)?, review: ApplicationCategory?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            HStack(spacing: 8) {
                if let primary {
                    Button(primary.0, action: primary.1).appButtonChrome(.primary)
                }
                if let review {
                    Button(L10n.text("检查", "Review")) { model.review(review) }.appButtonChrome(.secondary)
                }
            }
            .disabled(model.phase != .browsing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}
