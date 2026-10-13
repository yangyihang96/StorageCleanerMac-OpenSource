import SwiftUI

struct AppUninstallScanLandingView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        Group {
        if store.isLoadingInstalledApps {
            AppUninstallRunningPage()
        } else {
        FeatureLightfieldPage(module: .uninstall, phase: .landing, title: L10n.text("卸载", "Uninstall"),
            status: L10n.text("尚未读取应用列表", "App list not read"),
            safety: L10n.text("只读扫描 · 卸载前确认", "Read-only scan · Confirm before uninstalling"),
            actionTitle: L10n.text("读取应用列表", "Read App List"),
            actionEnabled: store.canRefreshInstalledApps, action: startScan) {
            FeatureLightfieldOptions(title: L10n.text("读取范围", "Read Scope")) {
                LightfieldOptionRow(title: "/Applications", icon: .uninstallApplication, module: .uninstall,
                    probeID: "lightfield.uninstall.option.system")
                LightfieldOptionRow(title: "~/Applications", icon: .uninstallContainers, module: .uninstall,
                    probeID: "lightfield.uninstall.option.user")
                LightfieldOptionRow(title: L10n.text("关联文件线索", "Related File Leads"),
                    icon: .uninstallRelatedFiles, module: .uninstall,
                    metadata: L10n.text("默认保留", "Kept by default"), probeID: "lightfield.uninstall.option.related")
            }
        }
        }
        }
        .featureFlowTransition(value: store.isLoadingInstalledApps)
    }

    private func startScan() {
        store.refreshInstalledApps()
    }
}
