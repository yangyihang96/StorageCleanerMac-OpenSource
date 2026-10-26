import SwiftUI

/// Presentation-only adapter over the existing verified catalog. Unknown
/// in-app update paths remain in Manage Updates, never in the updates count.
struct AppUpdateLightfieldPresentation {
    let summary: AppScanSummary
    let entries: [AppUpdateCatalogEntry]
    var confirmedUpdateCount: Int { summary.confirmedUpdateCount }
    init(summary: AppScanSummary) {
        self.summary = summary
        entries = AppUpdateCatalogSnapshot(summary: summary).entries.filter { $0.isUpdateAvailable || $0.application.updateStatus == .ignored }
    }
    var metrics: [LightfieldMetric] {
        Self.metrics(LastAppScanSummary(summary: summary))
    }
    static func metrics(_ summary: LastAppScanSummary) -> [LightfieldMetric] {
        [.init(id: "automatic", label: L10n.text("可直接更新", "Automatic"), value: String(summary.automaticCount), status: .normal),
         .init(id: "quit", label: L10n.text("退出后更新", "Quit First"), value: String(summary.requiresQuitCount), status: .warning),
         .init(id: "authorization", label: L10n.text("需授权", "Authorization"), value: String(summary.requiresAuthorizationCount), status: .warning),
         .init(id: "manual", label: L10n.text("需手动", "Manual"), value: String(summary.manualCount)),
         .init(id: "current", label: L10n.text("已是最新", "Current"), value: String(summary.currentCount)),
         .init(id: "unknown", label: L10n.text("状态未知", "Unknown"), value: String(summary.unknownCount), status: .unknown)]
    }
    var emptyMessage: String {
        IgnoreListSnapshot.appendingSummary(summary.ignoredCount, to: summary.completionState == .allCurrent
            ? L10n.text("所有应用都是最新版本", "All Apps Are Up to Date")
            : L10n.text("未发现可确认更新 · 可在管理更新中审阅手动检查与未知状态", "No confirmed updates · Review manual checks and unknown states in Manage Updates"))
    }
    static func handling(_ category: AppUpdateCatalogCategory) -> (status: MetadataPillStatus, title: String) {
        switch category {
        case .automatic: (.normal, L10n.text("可直接更新", "Automatic"))
        case .requiresQuit: (.warning, L10n.text("退出后更新", "Quit First"))
        case .requiresAuthorization: (.locked, L10n.text("需授权", "Authorization"))
        case .appStore: (.systemOnly, L10n.text("App Store", "App Store"))
        case .inApplication: (.readOnly, L10n.text("应用内更新", "In-App Update"))
        case .website: (.readOnly, L10n.text("官网处理", "Developer Website"))
        case .manual: (.readOnly, L10n.text("需手动", "Manual"))
        case .unknown: (.warning, L10n.text("状态未知", "Unknown"))
        case .systemManaged: (.systemOnly, L10n.text("系统管理", "System Managed"))
        }
    }
}

struct AppUpdateLightfieldRow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: AppUpdateCatalogEntry
    let index: Int
    let onReview: () -> Void
    /// D207: "加入忽略列表" in the row's menu; nil hides it.
    var onIgnore: (() -> Void)? = nil
    private var versions: String {
        entry.application.installedVersion.display + " → " + (entry.application.availableVersion?.display ?? "—")
    }
    var body: some View {
        let handling: (status: MetadataPillStatus, title: String) = entry.application.updateStatus == .ignored
            ? (.readOnly, L10n.text("已忽略", "Ignored"))
            : AppUpdateLightfieldPresentation.handling(entry.category)
        let probe = "lightfield.updater.item.\(index)"
        Button(action: onReview) {
            LightfieldListRow(kind: .updater, probeID: probe) {
                LightfieldAppIcon(path: entry.application.path, size: .medium)
                    .lightfieldComponentProbe(probe + ".icon")
            } name: {
                LightfieldApplicationName(title: entry.application.displayName, probeID: probe)
            } detail: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(versions).font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .lineLimit(1).truncationMode(.middle).help(versions)
                        .lightfieldComponentProbe(probe + ".versions")
                    Text(entry.application.source).font(.system(size: 12))
                        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3).lineLimit(1)
                    if !entry.canJoinAutomaticUpdateBatch, let reason = entry.application.updateError?.trimmed.nonEmpty {
                        Text(reason).font(.system(size: 12))
                            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                HStack(spacing: 8) {
                    LightfieldStatusGlyph(status: handling.status, tone: entry.category == .requiresAuthorization ? .warning : nil)
                    Text(handling.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).help(handling.title)
                        .foregroundStyle(entry.category == .requiresAuthorization
                            ? FeatureLightfieldPalette.resolve(scheme).warningColor
                            : handling.status.lightfieldColor(FeatureLightfieldPalette.resolve(scheme)))
                        .lightfieldComponentProbe(probe + ".handling")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(entry.application.displayName + " · " + versions)
            .accessibilityValue(handling.title)
            .accessibilityHint(L10n.text("打开更新管理，检查不会安装更新", "Open update management; checking does not install updates"))
            .contextMenu {
                if let onIgnore, entry.application.updateStatus != .ignored {
                    Button(IgnoreListMenu.title(count: 1), action: onIgnore)
                }
            }
            .lightfieldRowEntrance(index)
    }
}
