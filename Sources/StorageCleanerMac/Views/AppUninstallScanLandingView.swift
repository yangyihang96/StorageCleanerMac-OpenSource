import SwiftUI

struct AppUninstallScanLandingView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        if store.isLoadingInstalledApps {
            FeatureRuntimePage(module: .uninstall,
                title: L10n.text("正在读取应用信息", "Reading Application Information"),
                subtitle: L10n.text("正在检查应用大小及可确认的关联文件", "Checking app sizes and attributable related files"),
                trustText: L10n.text("只读扫描 · 卸载前确认", "Read-only scan · Confirm before uninstalling")) {
                EmptyView()
            } actions: {
                EmptyView()
            }
        } else {
        FeatureLandingPageShell(
            title: L10n.text("卸载", "Uninstall"),
            subtitle: ReviewFilter.uninstall.pageSubtitle,
            headerSystemImage: AppSymbols.Navigation.uninstall,
            actionTitle: store.isLoadingInstalledApps
                ? L10n.text("正在扫描", "Scanning")
                : L10n.text("读取应用列表", "Read App List"),
            actionDetail: store.isLoadingInstalledApps
                ? L10n.text("正在读取应用信息和关联文件…", "Reading apps and related files…")
                : L10n.text("读取已安装应用及其可确认的相关文件", "Review installed apps and attributable related files"),
            actionSystemImage: "square.grid.2x2.fill",
            status: store.isLoadingInstalledApps
                ? .scanning(L10n.text("正在读取已安装应用…", "Reading installed applications…"))
                : .idle(L10n.text("尚未读取应用列表", "App list not read")),
            isLoading: store.isLoadingInstalledApps,
            isActionDisabled: !store.canRefreshInstalledApps,
            trustText: L10n.text(
                "只读扫描，不会自动卸载任何应用",
                "Read-only scan; no app is uninstalled automatically"
            ),
            action: startScan
        )
        }
    }

    private func startScan() {
        store.refreshInstalledApps()
    }
}
