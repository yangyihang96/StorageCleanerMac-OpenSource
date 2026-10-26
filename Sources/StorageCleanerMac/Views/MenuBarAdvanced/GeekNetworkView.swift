import SwiftUI

/// D119: iStat's bandwidth section in the module menu (150): the readouts
/// at 6 with their legend at 25, the mirrored graph from 47 (H − 74 tall,
/// x 8 and W − 14 wide), the peak row at H − 21 (was a padded stack with a
/// 72 pt plot).
enum GeekNetworkBandwidthLayout {
    static let cardHeight: CGFloat = 150
    static var chartHeight: CGFloat { cardHeight - 74 }
    static var peakTop: CGFloat { cardHeight - 21 }
}

extension MenuBarAdvancedStatusView {
    /// D119: iStat's network menu (301 pt): the bandwidth, the interfaces
    /// (our VPN first), the public and the local addresses, the processes.
    var geekNetworkPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.network) { geekNetworkTrend }
            liveCard(.networkInterface) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
            if let tunnel = networkTopologySnapshot?.activeVPNTunnel {
                GeekVPNDisclosure(tunnel: tunnel, refresh: refreshPanelData)
            }
            geekPhysicalNetwork
            geekNetworkPublicAddress
            geekNetworkLocalAddresses
            geekNetworkProcessCard
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var geekNetworkTrend: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("网络活动历史三级详情", "Network Activity History Deep Detail"),
            chartRangeMetric: .network,
            popoverSize: GeekNetworkHistoryHoverDetail.popoverSize
        ) {
            geekNetworkTrendCard
        } detail: {
            GeekNetworkHistoryHoverDetail(
                points: networkChartHistory,
                duration: networkChartRange.duration,
                uploadValue: networkUpText,
                downloadValue: networkDownText,
                isUpdating: networkDisplayedHistory.isUpdating
            )
        }
    }

    private var geekNetworkTrendCard: some View {
        GeekIStatCard(height: GeekNetworkBandwidthLayout.cardHeight) {
            HStack(spacing: 0) {
                GeekSecondaryTransferValue(
                    title: L10n.text("上传", "Upload"),
                    value: networkUpText,
                    tint: resolvedUploadTint
                )
                GeekSecondaryTransferValue(
                    title: L10n.text("下载", "Download"),
                    value: networkDownText,
                    tint: resolvedDownloadTint
                )
            }
            .geekIStatLayer(top: GeekIStatCardGeometry.networkValueTop,
                            height: GeekIStatCardGeometry.networkReadoutHeight)

            GeekPrecisionNetworkChart(
                points: networkChartHistory,
                accessibilityLabel: L10n.text(
                    "最近 \(networkChartRange.title) 的网络上传与下载趋势",
                    "Network upload and download trends over the last \(networkChartRange.title)"
                ),
                duration: networkChartRange.duration,
                showsLegend: false,
                showsTimelineLabels: false,
                horizontalInset: 0,
                verticalInset: 0,
                mirroredHalfInset: 0,
                // D131: iStat's menu graph, one bar per sample.
                bucketing: .samples
            )
            .geekIStatLayer(top: GeekIStatCardGeometry.networkGraphTop,
                            height: GeekNetworkBandwidthLayout.chartHeight,
                            trailing: GeekIStatCardGeometry.processorGraphTrailingInset)
            // iStat's peak row, upload at the leading inset and download at
            // the trailing one. D146: the peaks of the bars the graph draws
            // (were the window's peaks with arrows and what our session had
            // moved).
            // A layer spans the card, so the row keeps the card's offsets.
            .overlayPreferenceValue(GeekMirroredChartPeaksKey.self) { peaks in
                GeekNetworkPeakRow(peaks: peaks)
                    .geekIStatLayer(top: GeekNetworkBandwidthLayout.peakTop, height: GeekIStatCardGeometry.titleHeight)
            }
        }
    }

    /// D140: iStat's public IP section (`BBRNetworkMenuIPSectionPublic`,
    /// `-[NetworkMenu updatePublicAddresses]`): the public IPv4 and IPv6
    /// addresses as last looked up, the country's flag, the refresh icon while
    /// hovered (was the IPv4 address in the title row and IPv6 below it).
    private var geekNetworkPublicAddress: some View {
        GeekPublicNetworkAddressSection(
            snapshot: publicNetworkAddressSnapshot,
            isLoading: !store.isMenuBarRefreshPaused && isRefreshingPublicNetworkAddress,
            refresh: requestPublicNetworkAddressRefresh
        )
        .accessibilityHint(L10n.text(
            "极客概览显示网络模块时预取公网地址，成功结果缓存 15 分钟。",
            "Public addresses are prefetched while the Network module is visible in Geek Overview and successful results are cached for 15 minutes."
        ))
    }

    /// D140: iStat's IP section (`-[NetworkMenu privateAddresses]`): every
    /// listed address of the connection and the VPNs (was the first IPv4 and
    /// the first IPv6 address, titled "本地 IP 地址").
    private var geekNetworkLocalAddresses: some View {
        let isReading = !store.isMenuBarRefreshPaused && networkTopologySnapshot == nil && networkInterfaceSnapshot == nil
        return GeekIStatIPSection(
            title: GeekIStatInterfaceModel.addressesTitle,
            addresses: geekNetworkListedAddresses,
            status: isReading ? L10n.text("正在读取…", "Reading…") : L10n.text("没有 IP 地址", "No IP Addresses")
        )
    }

    /// iStat's list: the addresses of each connected interface it lists
    /// (`NetworkAddressListing`), the connection's then the VPNs', every IPv4
    /// address before the IPv6 ones. A snapshot without the list keeps the
    /// connection's first IPv4 and IPv6 addresses.
    var geekNetworkListedAddresses: [String] {
        NetworkAddressListing.menuAddresses(
            connection: geekConnectionSnapshot.ipConfiguration.listedAddresses
                ?? [geekPhysicalIPv4Address, geekPhysicalIPv6Address].compactMap { $0 },
            tunnels: [networkTopologySnapshot?.activeVPNTunnel].compactMap { $0 }
                + (networkTopologySnapshot?.additionalVPNTunnels ?? [])
        )
    }

    /// D140: the public section's refresh icon (`onRefresh`): looks the
    /// public addresses up again; nothing in the demo.
    func requestPublicNetworkAddressRefresh() {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return }
#endif
        auxiliaryState.requestPublicNetworkAddressRefresh()
    }

    private var geekPhysicalNetwork: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "连接方式，\(geekPhysicalNetworkTitle)，\(geekPhysicalNetworkDetail)，显示详情",
                "Connection, \(geekPhysicalNetworkTitle), \(geekPhysicalNetworkDetail), show details"
            ),
            popoverSize: GeekNetworkTertiaryView.preferredSize(for: geekConnectionSnapshot)
        ) {
            GeekNetworkTopologyRow(
                title: geekPhysicalNetworkTitle,
                detail: geekPhysicalNetworkDetail,
                symbol: geekPhysicalNetworkSymbol,
                tint: Color.accentColor,
                accessibilityLabel: L10n.text(
                    "物理网络，\(geekPhysicalNetworkTitle)，\(geekPhysicalNetworkDetail)",
                    "Physical network, \(geekPhysicalNetworkTitle), \(geekPhysicalNetworkDetail)"
                )
            )
        } detail: {
            GeekNetworkTertiaryView(
                snapshot: networkInterfaceSnapshot,
                topology: networkTopologySnapshot,
                refresh: refreshPanelData
            )
        }
        .accessibilityIdentifier("network.connection.inspector")
    }

    /// D119: iStat's process section with the upload and download columns;
    /// it keeps the height of its row capacity (was one row per process).
    private var geekNetworkProcessCard: some View {
        GeekIStatProcessSection(rowCapacity: geekNetworkProcessCapacity) {
            GeekNetworkProcessHeader(status: geekNetworkProcessSampleTimeText)
        } rows: {
            geekNetworkProcessRows
        }
        .accessibilityElement(children: .combine)
    }

    private var geekNetworkProcessCapacity: Int {
        showsExtendedGeekDetails ? 4 : 2
    }

    @ViewBuilder
    private var geekNetworkProcessRows: some View {
        if !displayedNetworkProcesses.isEmpty {
            ForEach(displayedNetworkProcesses) { process in
                GeekNetworkProcessRow(process: process)
            }
        } else {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                if !store.isMenuBarRefreshPaused && (networkProcessSamplingState == .sampling
                    || networkProcessSamplingState == .idle) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(geekNetworkProcessStatusText)
                    .lineLimit(1)
            }
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: GeekIStatSectionGeometry.rowHeight, alignment: .leading)
            .accessibilityLabel(geekNetworkProcessStatusAccessibilityText)
        }
    }

    private var displayedNetworkProcesses: [NativeNetworkProcessTransfer] {
        guard let snapshot = networkProcessSnapshot else { return [] }
        return Array(snapshot.processes.prefix(geekNetworkProcessCapacity))
    }

    /// BOARD N16-2: the shown processes' sample time, as on the CPU page. A
    /// measurement kept from before the panel was hidden is shown at once
    /// with its time until the next one replaces it.
    private var geekNetworkProcessSampleTimeText: String? {
        guard let snapshot = networkProcessSnapshot else { return nil }
        return GeekOnDemandSnapshotFreshness.statusText(generatedAt: snapshot.generatedAt)
    }

    private var geekNetworkProcessStatusText: String {
        if store.isMenuBarRefreshPaused { return L10n.text("已暂停", "Paused") }
        return switch networkProcessSamplingState {
        case .sampling:
            L10n.text("正在采样…", "Sampling…")
        case .unavailable:
            L10n.text("暂时无法读取进程流量", "Process Transfer Unavailable")
        case .available:
            L10n.text("暂无活动网络进程", "No Active Network Processes")
        case .idle:
            L10n.text("正在准备采样…", "Preparing Sample…")
        }
    }

    private var geekNetworkProcessStatusAccessibilityText: String {
        if store.isMenuBarRefreshPaused { return L10n.text("自动刷新已暂停", "Automatic refresh paused") }
        return switch networkProcessSamplingState {
        case .sampling:
            L10n.text("正在采样逐进程网络流量", "Sampling per-process network transfer")
        case .unavailable:
            L10n.text("暂时无法读取逐进程网络流量", "Per-process network transfer unavailable")
        case .available:
            L10n.text("暂无活动网络进程", "No active network processes")
        case .idle:
            L10n.text("正在准备逐进程网络流量采样", "Preparing per-process network transfer sampling")
        }
    }

    private var geekPhysicalNetworkTitle: String {
        guard networkTopologySnapshot != nil || networkInterfaceSnapshot != nil else {
            return store.isMenuBarRefreshPaused
                ? L10n.text("已暂停", "Paused")
                : L10n.text("正在读取物理网络…", "Reading physical network…")
        }
        switch geekConnectionSnapshot.connectionKind {
        case .wifi:
            return geekConnectionSnapshot.activeInterface?.displayName ?? "Wi-Fi"
        case .ethernet, .other:
            return geekConnectionSnapshot.activeInterface?.displayName
                ?? L10n.text("有线网络", "Ethernet")
        case .disconnected:
            return geekConnectionSnapshot.wifi == nil
                ? L10n.text("未连接", "Disconnected")
                : "Wi-Fi"
        }
    }

    private var geekPhysicalNetworkDetail: String {
        guard networkTopologySnapshot != nil || networkInterfaceSnapshot != nil else { return "—" }
        var parts: [String] = []
        if geekConnectionSnapshot.isConnected {
            if let ssid = geekConnectionSnapshot.wifi?.ssid {
                parts.append(ssid)
            }
            parts.append(L10n.text("已连接", "Connected"))
        } else if let wifi = geekConnectionSnapshot.wifi {
            parts.append(wifi.powerState == .off
                ? L10n.text("已关闭", "Off")
                : L10n.text("已开启 · 未连接", "On · Disconnected"))
        } else {
            parts.append(L10n.text("未连接", "Disconnected"))
        }
        if geekConnectionSnapshot.isVPNActive {
            parts.append(L10n.text("VPN 已连接", "VPN Connected"))
        }
        return parts.joined(separator: " · ")
    }

    private var geekPhysicalNetworkSymbol: String {
        geekConnectionSnapshot.connectionKind == .wifi
            || geekConnectionSnapshot.wifi != nil ? "wifi" : "network"
    }

    private var geekConnectionSnapshot: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(
            native: networkInterfaceSnapshot,
            topology: networkTopologySnapshot
        )
    }

    private var geekPhysicalIPv4Address: String? {
        if let transport = networkTopologySnapshot?.physicalTransport,
           let address = transport.ipv4Addresses.first {
            return address
        }
        if let address = networkTopologySnapshot?.physicalAddresses.first(where: {
            $0.address.contains(".")
        }) {
            return address.address
        }
        return legacyPhysicalNetworkSnapshot?.ipv4Addresses.first
    }

    private var geekPhysicalIPv6Address: String? {
        let addresses = networkTopologySnapshot?.physicalTransport?.ipv6Addresses
            ?? networkTopologySnapshot?.physicalAddresses
                .filter { $0.address.contains(":") }
                .map(\.address)
            ?? legacyPhysicalNetworkSnapshot?.ipv6Addresses
            ?? []
        return addresses.first(where: { !$0.lowercased().hasPrefix("fe80:") })
            ?? addresses.first
    }

    private var legacyPhysicalNetworkSnapshot: NativeNetworkInterfaceSnapshot? {
        guard let snapshot = networkInterfaceSnapshot,
              let name = snapshot.interfaceName?.lowercased(),
              !["ipsec", "utun", "ppp", "tun", "tap", "vpn"].contains(where: name.hasPrefix) else {
            return nil
        }
        return snapshot
    }
}

private struct GeekNetworkProcessHeader: View {
    @Environment(\.panelMetricColors) private var metricColors
    var status: String? = nil
    var body: some View {
        GeekProcessListHeader(
            title: L10n.text("进程", "PROCESSES"),
            status: status,
            columns: [
                // The same words as the page's legends (上传 / 下载, Upload / Download).
                GeekProcessListColumn(id: "upload", title: L10n.text("上传", "Upload"),
                                      tint: metricColors.networkUpload,
                                      accessibilityLabel: L10n.text("上传速率", "Upload rate")),
                GeekProcessListColumn(id: "download", title: L10n.text("下载", "Download"),
                                      tint: metricColors.networkDownload,
                                      accessibilityLabel: L10n.text("下载速率", "Download rate")),
            ]
        )
    }
}

/// D119: a row of iStat's process section with the upload and download
/// columns, aligned on the header's column labels.
struct GeekNetworkProcessRow: View {
    let process: NativeNetworkProcessTransfer

    var body: some View {
        GeekIStatProcessRow(iconPath: process.iconPath, fallbackSymbol: AppSymbols.Monitor.network,
                            name: process.name) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                GeekSecondaryTransferReadout(
                    value: IStatNumberFormat.bandwidth(process.uploadBytesPerSecond, style: .process),
                    numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                    unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                    minimumScale: GeekSecondaryTransferLayout.processMinimumScale
                )
                .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)

                GeekSecondaryTransferReadout(
                    value: IStatNumberFormat.bandwidth(process.downloadBytesPerSecond, style: .process),
                    numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                    unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                    minimumScale: GeekSecondaryTransferLayout.processMinimumScale
                )
                .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)
            }
        }
        .help(L10n.text(
            "\(process.name)：上传 \(uploadText)，下载 \(downloadText)",
            "\(process.name): upload \(uploadText), download \(downloadText)"
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(process.name)
        .accessibilityValue(L10n.text(
            "上传 \(uploadText)，下载 \(downloadText)",
            "Upload \(uploadText), download \(downloadText)"
        ))
    }

    /// D128: help and VoiceOver spell the rates out in iStat's row format
    /// ("12 KB/s"); the row itself shows its short "12 K".
    private var uploadText: String {
        IStatNumberFormat.bandwidth(process.uploadBytesPerSecond)
    }

    private var downloadText: String {
        IStatNumberFormat.bandwidth(process.downloadBytesPerSecond)
    }
}

/// D146: iStat's bandwidth peak row, "Label: value" with 'Network.Upload'
/// and 'Network.Download' (was an arrow in the direction's color, the peak
/// and what our session had moved). The peaks are in iStat's bandwidth
/// format; "--" until the graph has a frame.
struct GeekNetworkPeakRow: View {
    let uploadPeak: String
    let downloadPeak: String

    var body: some View {
        GeekIStatPeakRow(
            leading: GeekIStatPeakValue(title: L10n.text("上传", "Upload"), value: uploadPeak,
                accessibilityLabel: L10n.text("上传峰值", "Upload peak")),
            trailing: GeekIStatPeakValue(title: L10n.text("下载", "Download"), value: downloadPeak,
                accessibilityLabel: L10n.text("下载峰值", "Download peak"))
        )
    }
}

extension GeekNetworkPeakRow {
    init(peaks: GeekMirroredChartPeaks?) {
        self.init(uploadPeak: peaks?.upward.map { IStatNumberFormat.bandwidth($0) } ?? "--",
                  downloadPeak: peaks?.downward.map { IStatNumberFormat.bandwidth($0) } ?? "--")
    }
}

/// D140: iStat's public IP section: the addresses it has (IPv4, then
/// IPv6), the flag of the IPv4 address's country (else the IPv6 one's), and
/// the refresh icon. Missing preferences use the shared default. With the
/// lookup switched off (Settings › Access) the section is not there, as
/// iStat's with its public addresses off (was "未开启 · 设置 › 权限" in the
/// section).
struct GeekPublicNetworkAddressSection: View {
    @AppStorage(PublicNetworkConsent.addressKey) private var isLookupAllowed = PublicNetworkConsent.defaultAllowsAddress
    let snapshot: PublicNetworkAddressSnapshot?
    let isLoading: Bool
    let refresh: () -> Void

    var body: some View {
        if isLookupAllowed {
            GeekIStatIPSection(
                title: L10n.text("公共 IP 地址", "Public IP Addresses"),
                addresses: Self.addresses(snapshot),
                flag: Self.flag(snapshot),
                refresh: refresh,
                status: isLoading ? L10n.text("正在读取…", "Reading…") : L10n.text("暂不可用", "Unavailable")
            )
        }
    }

    static func addresses(_ snapshot: PublicNetworkAddressSnapshot?) -> [String] {
        [snapshot?.ipv4Address, snapshot?.ipv6Address].compactMap { address in
            guard let address, !address.isEmpty else { return nil }
            return address
        }
    }

    static func flag(_ snapshot: PublicNetworkAddressSnapshot?) -> String? {
        PublicNetworkAddressService.flagEmoji(forCountryCode: snapshot?.ipv4CountryCode ?? snapshot?.ipv6CountryCode)
    }
}

/// D119: an interface in iStat's 25 pt row: the glyph and the name on the
/// left, the state on the right (was a 39 pt card).
private struct GeekNetworkTopologyRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let accessibilityLabel: String
    var showsDisclosure = false

    var body: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.singleRowHeight) {
            HStack(spacing: GeekIStatCardGeometry.legendDotSpacing) {
                GeekModuleIcon(systemImage: symbol, tint: tint)

                Text(title)
                    .geekIStatLabelText()
                    .layoutPriority(1)

                Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)

                Text(detail)
                    .geekIStatValueText()
                    .truncationMode(.middle)

                if showsDisclosure {
                    GeekDisclosureIcon()
                }
            }
            .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GeekVPNDisclosure: View {
    let tunnel: VPNTunnelSnapshot
    let refresh: () -> Void

    var body: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("VPN 连接详情", "VPN Connection Details"),
            popoverSize: GeekVPNHoverDetail.preferredSize(for: tunnel),
            sourceOffset: 158
        ) {
            GeekNetworkTopologyRow(
                title: tunnel.displayName,
                detail: "\(tunnel.protocolKind.displayName) · \(vpnStatusText(tunnel.status))",
                symbol: "lock.shield",
                tint: vpnStatusTint(tunnel.status),
                accessibilityLabel: L10n.text(
                    "VPN，\(tunnel.displayName)，\(vpnStatusText(tunnel.status))",
                    "VPN, \(tunnel.displayName), \(vpnStatusText(tunnel.status))"
                ),
                showsDisclosure: true
            )
            .help(L10n.text("查看 VPN 连接详情", "Show VPN connection details"))
        } detail: {
            GeekVPNHoverDetail(tunnel: tunnel, refresh: refresh)
        }
    }
}

/// D125: a VPN's page is iStat's interface submenu. iStat lists a VPN as an
/// interface, its row drawn with a lock, and opens the same submenu for it
/// (`-[NetworkMenu updateInterfaceSubmenu]`): the interface section with
/// the tunnel's BSD name, its addresses, and IPv4 / IPv6 with the router
/// and every scoped DNS server (was a status card, a details card with
/// three DNS rows and "N more", and a management card; the status stays in
/// the row and the page's accessibility label). iStat ends with its
/// disconnect button (type 2) for a connection it can switch. Ours is the
/// management action of the tunnel's capability in that item: the macOS
/// disconnect request, which asks first, or opening the VPN's app or System
/// Settings as a standard button. The action's description is its help;
/// its result shows as a note below it.
struct GeekVPNHoverDetail: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset

    let tunnel: VPNTunnelSnapshot
    let refresh: () -> Void
    private let capabilityResolver: VPNControlCapabilityResolver
    private let controlAction: @Sendable (VPNTunnelSnapshot) async -> VPNControlResult

    @State private var isConfirmingDisconnect = false
    @State private var isPerformingAction = false
    @State private var actionMessage: String?

    private static let controlService = VPNControlService()

    init(
        tunnel: VPNTunnelSnapshot,
        refresh: @escaping () -> Void,
        capabilityResolver: VPNControlCapabilityResolver = VPNControlCapabilityResolver(),
        initiallyConfirmsDisconnect: Bool = false,
        controlAction: (@Sendable (VPNTunnelSnapshot) async -> VPNControlResult)? = nil
    ) {
        self.tunnel = tunnel
        self.refresh = refresh
        self.capabilityResolver = capabilityResolver
        self.controlAction = controlAction ?? { tunnel in
            await Self.controlService.perform(for: tunnel)
        }
        _isConfirmingDisconnect = State(initialValue: initiallyConfirmsDisconnect)
    }

    private var preflight: VPNControlPreflight {
        capabilityResolver.preflight(for: tunnel)
    }

    /// The page's first size: its sections and, when the tunnel may offer an
    /// action, the 31 pt button, 7 apart inside the 8 pt insets. The column
    /// then measures the page, so a result's note makes it taller. D137: as
    /// wide as its widest section or button + 20, iStat's interface submenu
    /// (was `GeekHoverDetailMetrics.vpnWidth`, 220 for every tunnel); the
    /// button counts the widest action title, since the size reads the
    /// tunnel only.
    static func preferredSize(for tunnel: VPNTunnelSnapshot) -> CGSize {
        let model = GeekIStatInterfaceModel(tunnel: tunnel)
        let reservesButton = reservesActionButton(for: tunnel)
        let width = model.pageWidth(buttonTitles: reservesButton ? actionTitles : [])
        var cards = model.sectionHeights(pageWidth: width)
        if reservesButton {
            cards.append(GeekIStatInterfaceGeometry.buttonHeight)
        }
        return CGSize(
            width: width,
            height: GeekIStatDetailGeometry.pageHeight(cards: cards)
        )
    }

    var body: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            GeekIStatInterfaceSections(model: GeekIStatInterfaceModel(tunnel: tunnel)) {
                EmptyView()
            }

            if let action = Self.actionPresentation(for: preflight) {
                GeekIStatButtonItem(
                    title: action.title,
                    kind: action.isDestructive ? .destructive : .standard,
                    isBusy: isPerformingAction,
                    action: requestAction
                )
                .disabled(isPerformingAction || !preflight.canExecute)
                .help(managementDescription)
#if DEBUG
                .layoutProbe("vpn.action")
#endif
            }

            if let actionMessage {
                GeekIStatNoteCard(text: actionMessage)
#if DEBUG
                    .layoutProbe("vpn.note")
#endif
            }
        }
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(
            "VPN，\(tunnel.displayName)，\(vpnStatusText(tunnel.status))",
            "VPN, \(tunnel.displayName), \(vpnStatusText(tunnel.status))"
        ))
        .confirmationDialog(
            L10n.text("断开 VPN？", "Disconnect VPN?"),
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button(L10n.text("断开连接", "Disconnect"), role: .destructive) {
                performAction()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "应用会向 macOS 提交断开请求；连接是否已断开将以随后读取到的系统状态为准。",
                "The app submits a disconnect request to macOS. A later system refresh confirms the actual state."
            ))
        }
    }

    /// Every capability with an action needs a service identity or a provider
    /// app (`VPNControlCapabilityResolver`); a tunnel with neither is
    /// read-only. Reads the tunnel only, so sizing the row's page never runs
    /// the SystemConfiguration preflight.
    static func reservesActionButton(for tunnel: VPNTunnelSnapshot) -> Bool {
        guard tunnel.status != .invalid else { return false }
        let serviceID = tunnel.serviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !serviceID.isEmpty || tunnel.providerApplicationURL != nil
    }

    /// The management action, if any. Only the macOS disconnect request is
    /// destructive (U1 085); opening the provider app or System Settings is not.
    static func actionPresentation(for preflight: VPNControlPreflight) -> GeekVPNManagementAction? {
        guard preflight.canExecute else { return nil }
        switch preflight.capability {
        case .systemConfigurationConnection:
            return GeekVPNManagementAction(title: disconnectTitle, isDestructive: true)
        case .openProviderApplication:
            return GeekVPNManagementAction(title: openApplicationTitle, isDestructive: false)
        case .openSystemSettingsOnly:
            return GeekVPNManagementAction(title: openSystemSettingsTitle, isDestructive: false)
        case .ownedNEVPNConnection, .readOnly, .unsupported:
            return nil
        }
    }

    static var disconnectTitle: String { L10n.text("断开连接", "Disconnect") }
    static var openApplicationTitle: String { L10n.text("打开 VPN 应用", "Open VPN App") }
    static var openSystemSettingsTitle: String { L10n.text("打开系统设置", "Open System Settings") }
    static var actionTitles: [String] { [disconnectTitle, openApplicationTitle, openSystemSettingsTitle] }

    private var managementDescription: String {
        if let failure = preflight.failure {
            return failureText(failure)
        }
        switch preflight.capability {
        case .systemConfigurationConnection:
            return L10n.text("此 PPP VPN 可由 macOS 提交断开请求。", "macOS can submit a disconnect request for this PPP VPN.")
        case .openProviderApplication:
            return L10n.text("此第三方 VPN 需在其应用中管理。", "Manage this third-party VPN in its own app.")
        case .openSystemSettingsOnly:
            return L10n.text("此 VPN 只能在系统设置中管理。", "Manage this VPN in System Settings.")
        case .ownedNEVPNConnection:
            return L10n.text("当前没有可用的应用内 VPN 连接。", "No app-owned VPN connection is available.")
        case .readOnly:
            return L10n.text("此连接仅提供状态监测，无法安全控制。", "This connection is status-only and cannot be safely controlled.")
        case .unsupported:
            return L10n.text("此连接无法安全管理。", "This connection cannot be safely managed.")
        }
    }

    private func requestAction() {
        guard preflight.canExecute else { return }
        if case .systemConfigurationConnection = preflight.capability {
            isConfirmingDisconnect = true
        } else {
            performAction()
        }
    }

    private func performAction() {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        actionMessage = nil

        Task { @MainActor in
            let result = await controlAction(tunnel)
            isPerformingAction = false
            actionMessage = actionResultText(result)
            if case .stopRequestSubmitted = result {
                refresh()
            }
        }
    }

    private func actionResultText(_ result: VPNControlResult) -> String {
        switch result {
        case .stopRequestSubmitted:
            return L10n.text("已向 macOS 提交断开请求，正在刷新状态。", "Disconnect request submitted to macOS; refreshing status.")
        case .openedProviderApplication:
            return L10n.text("已打开 VPN 应用。", "VPN app opened.")
        case .openedSystemSettings:
            return L10n.text("已打开系统设置。", "System Settings opened.")
        case .alreadyInProgress:
            return L10n.text("操作正在进行。", "Action already in progress.")
        case .unavailable(let failure):
            return failureText(failure)
        }
    }

    private func failureText(_ failure: VPNControlFailure) -> String {
        switch failure {
        case .connectionNotActive:
            return L10n.text("该 VPN 当前未处于可断开状态。", "This VPN is not in a disconnectable state.")
        case .ownedConnectionUnavailable:
            return L10n.text("应用内 VPN 连接不可用。", "The app-owned VPN connection is unavailable.")
        case .providerApplicationUnavailable:
            return L10n.text("无法打开 VPN 应用。", "Unable to open the VPN app.")
        case .systemSettingsUnavailable:
            return L10n.text("无法打开系统设置。", "Unable to open System Settings.")
        case .readOnly:
            return L10n.text("此连接仅供查看。", "This connection is read-only.")
        case .unsupported:
            return L10n.text("此连接不受支持。", "This connection is unsupported.")
        case .systemConnectionUnavailable:
            return L10n.text("macOS 当前无法管理该连接。", "macOS cannot manage this connection right now.")
        case .stopRequestRejected:
            return L10n.text("macOS 未接受断开请求。", "macOS did not accept the disconnect request.")
        }
    }
}

struct GeekVPNManagementAction: Equatable {
    let title: String
    let isDestructive: Bool
}

private func vpnStatusText(_ status: VPNStatus) -> String {
    switch status {
    case .connecting:
        return L10n.text("正在连接", "Connecting")
    case .connected:
        return L10n.text("已连接", "Connected")
    case .reconnecting:
        return L10n.text("正在重连", "Reconnecting")
    case .disconnecting:
        return L10n.text("正在断开", "Disconnecting")
    case .disconnected:
        return L10n.text("未连接", "Disconnected")
    case .invalid:
        return L10n.text("无效", "Invalid")
    case .unknown:
        return L10n.text("状态未知", "Unknown")
    }
}

private func vpnStatusTint(_ status: VPNStatus) -> Color {
    switch status {
    case .connected:
        return AppDesignTokens.Palette.success
    case .connecting, .reconnecting, .disconnecting:
        return AppDesignTokens.Palette.warning
    case .disconnected, .invalid, .unknown:
        return .secondary
    }
}

/// D125: the physical connection's page is iStat's interface submenu
/// (`-[NetworkMenu updateInterfaceSubmenu]`, `GeekIStatInterfaceSections`):
/// the interface, a wired link's media options, Wi-Fi with its power
/// switch, the addresses, IPv4 and IPv6, each section only with something
/// to show (was five fixed cards with "—" and "Not Configured" rows in the
/// 255 × 419 `referenceSize`). The column measures the page, so it follows
/// its rows. iStat's "Renew DHCP Lease" button is not copied: it changes
/// the system's network configuration.
struct GeekNetworkTertiaryView: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset

    let snapshot: NativeNetworkInterfaceSnapshot?
    let topology: NetworkTopologySnapshot?
    let refresh: () -> Void
    let contentPadding: CGFloat
    @ObservedObject private var wiFiPowerControl: WiFiPowerControlCoordinator
    @State private var revealsHardwareAddress = false

    init(
        snapshot: NativeNetworkInterfaceSnapshot?,
        topology: NetworkTopologySnapshot? = nil,
        refresh: @escaping () -> Void,
        contentPadding: CGFloat = GeekPanelLayout.contentPadding
    ) {
        self.snapshot = snapshot
        self.topology = topology
        self.refresh = refresh
        self.contentPadding = contentPadding
        _wiFiPowerControl = ObservedObject(wrappedValue: .shared)
    }

    /// The page's first size for `connection`: its sections 7 apart inside
    /// the 8 pt insets. D137: as wide as its widest section + 20, iStat's
    /// interface submenu (was 255 for every connection).
    static func preferredSize(for connection: NetworkConnectionSnapshot) -> CGSize {
        let model = GeekIStatInterfaceModel(connection: connection)
        return CGSize(
            width: model.pageWidth(),
            height: GeekIStatDetailGeometry.pageHeight(cards: model.sectionHeights)
        )
    }

    var body: some View {
        let model = GeekIStatInterfaceModel(connection: connection)
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            GeekIStatInterfaceSections(
                model: model,
                revealsHardwareAddress: $revealsHardwareAddress
            ) {
                wiFiHeaderStatus
            }
        }
        .padding(pageProvidesInset ? 0 : contentPadding)
        .frame(width: pageProvidesInset ? nil : model.pageWidth(), alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .onAppear {
            wiFiPowerControl.synchronize(confirmedPower: snapshot?.isWiFiPoweredOn)
        }
        .onChange(of: snapshot?.isWiFiPoweredOn) { _, power in
            wiFiPowerControl.synchronize(confirmedPower: power)
        }
        .onChange(of: wiFiPowerControl.completionGeneration) { _, _ in
            refresh()
        }
    }

    /// The Wi-Fi section's switch (iStat's `BBRMenuToggle`, 26 × 14 at 8
    /// from the right). Ours asks before turning Wi-Fi off, spins while a
    /// change applies and puts a warning before the switch after a change
    /// failed; the state is the help.
    private var wiFiHeaderStatus: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            if wiFiPowerControl.lastError != nil, !wiFiPowerControl.isApplying {
                Image(systemName: AppSymbols.Status.warning)
                    .font(AdvancedPanelTypography.symbol)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .accessibilityLabel(wiFiPowerStatusText)
            }
            GeekWiFiPowerControl(
                powerState: displayedWiFiPowerState,
                coordinator: wiFiPowerControl
            )
        }
        .fixedSize()
        .help(wiFiPowerHelpText)
    }

    private var connection: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(native: snapshot, topology: topology)
    }

    private var displayedWiFiPowerState: WiFiPowerState {
        wiFiPowerControl.displayedState(base: connection.wifi?.powerState ?? .unavailable)
    }

    private var wiFiPowerStatusText: String {
        if wiFiPowerControl.lastError != nil, !wiFiPowerControl.isApplying {
            return L10n.text("切换失败", "Change Failed")
        }
        return switch displayedWiFiPowerState {
        case .onConnected: L10n.text("已开启 · 已连接", "On · Connected")
        case .onDisconnected: L10n.text("已开启 · 未连接", "On · Disconnected")
        case .off: L10n.text("已关闭", "Off")
        case .changingToOn: L10n.text("正在开启…", "Turning On…")
        case .changingToOff: L10n.text("正在关闭…", "Turning Off…")
        case .unavailable: L10n.text("不可用", "Unavailable")
        }
    }

    private var wiFiPowerHelpText: String {
        guard let error = wiFiPowerControl.lastError else { return wiFiPowerStatusText }
        switch error {
        case .unavailable:
            return L10n.text("系统未提供可控制的 Wi-Fi 接口。", "No controllable Wi-Fi interface is available.")
        case .verificationFailed:
            return L10n.text("系统回读状态与请求不一致，未确认更改。", "System readback did not match the request.")
        case .operationRejected:
            return L10n.text("macOS 未允许更改 Wi-Fi；当前状态未伪造为成功。", "macOS did not allow the Wi-Fi change.")
        }
    }
}

extension GeekIStatInterfaceModel {
    /// The physical connection: the active interface's BSD name and MAC
    /// address, a wired link's speed and the media options, the Wi-Fi section
    /// while Wi-Fi is the connection or nothing is connected, the addresses,
    /// and IPv4 / IPv6 with every subnet mask, router and DNS server. D134:
    /// as in iStat, the speed and the media options only while connected,
    /// the speed for a link other than Wi-Fi with an `IOLinkSpeed`.
    init(connection: NetworkConnectionSnapshot) {
        bsdName = Self.meaningful(connection.activeInterface?.bsdName)
        hardwareAddress = Self.meaningful(connection.activeInterface?.hardwareAddress)?.uppercased()
        if connection.isConnected {
            linkSpeed = connection.ethernet?.linkSpeedMbps.map {
                Self.linkSpeedText(Self.displayedLinkSpeed($0, mediaSubType: connection.mediaSubType))
            }
            mediaOptions = Self.mediaOptions(connection.mediaOptions)
        }
        if let wifi = connection.wifi,
           connection.connectionKind == .wifi || connection.connectionKind == .disconnected {
            wiFiRows = Self.wiFiRows(wifi)
        }
        // D140: the addresses iStat lists (`NetworkAddressListing`); a
        // snapshot without the list keeps every IPv4 and IPv6 address.
        addresses = connection.ipConfiguration.listedAddresses
            ?? Self.meaningful(connection.ipConfiguration.ipv4Addresses)
            + Self.meaningful(connection.ipConfiguration.ipv6Addresses)
        ipv4Rows = Self.meaningful(connection.ipConfiguration.subnetMasks).map {
            Row(title: Self.subnetMaskTitle, value: $0)
        }
        if let router = Self.meaningful(connection.ipConfiguration.ipv4Router) {
            ipv4Rows.append(Row(title: Self.routerTitle, value: router))
        }
        let dnsServers = Self.meaningful(connection.ipConfiguration.dnsServers)
        ipv4Rows += dnsServers.filter { !$0.contains(":") }.map { Row(title: "DNS", value: $0) }
        if let router = Self.meaningful(connection.ipConfiguration.ipv6Router) {
            ipv6Rows.append(Row(title: Self.routerTitle, value: router))
        }
        ipv6Rows += dnsServers.filter { $0.contains(":") }.map { Row(title: "DNS", value: $0) }
    }

    /// A VPN: the tunnel's BSD name and addresses; its router (the service's
    /// `Router`) and its scoped DNS servers in the IPv4 or IPv6 section of
    /// their family. Every DNS server is a row, as in iStat. D140: the
    /// addresses iStat lists, so a point-to-point tunnel's own addresses
    /// (`utun`, `ppp`) are not there and neither is the section; a snapshot
    /// without the list keeps `tunnel.tunnelIPv4` and `tunnel.tunnelIPv6`.
    init(tunnel: VPNTunnelSnapshot) {
        bsdName = Self.meaningful(tunnel.bsdName)
        addresses = tunnel.listedAddresses
            ?? Self.meaningful(tunnel.tunnelIPv4) + Self.meaningful(tunnel.tunnelIPv6)
        if let router = Self.meaningful(tunnel.gatewayOrRemoteAddress) {
            let row = Row(title: Self.routerTitle, value: router)
            if router.contains(":") { ipv6Rows.append(row) } else { ipv4Rows.append(row) }
        }
        let dnsServers = Self.meaningful(tunnel.scopedDNSServers)
        ipv4Rows += dnsServers.filter { !$0.contains(":") }.map { Row(title: "DNS", value: $0) }
        ipv6Rows += dnsServers.filter { $0.contains(":") }.map { Row(title: "DNS", value: $0) }
    }

    // iStat's labels (`BBRMenuKit.strings`, zh-CN and en), looked up one by
    // one.
    static var interfaceTitle: String { L10n.text("接口", "Interface") }
    static var bsdNameTitle: String { L10n.text("BSD名称", "BSD") }
    static var hardwareAddressTitle: String { L10n.text("MAC地址", "MAC Address") }
    static var linkSpeedTitle: String { L10n.text("链接速度", "Link Speed") }
    static var mediaOptionsTitle: String { L10n.text("介质选项", "Media Options") }
    static var addressesTitle: String { L10n.text("IP 地址", "IP Addresses") }
    static var subnetMaskTitle: String { L10n.text("子网掩码", "Subnet Mask") }
    static var routerTitle: String { L10n.text("路由器", "Router") }

    /// iStat's link speed: below 1000 in Mb/s ("%li", so 0 is "0 Mb/s"), 1
    /// and 10 Gb/s whole, any other speed in Gb/s with one decimal of the
    /// single-precision quotient (`floatValue / 1000`, "%.1f"). D134: a zero
    /// speed is a row as in iStat (before: no row).
    static func linkSpeedText(_ megabits: Int) -> String {
        switch megabits {
        case ..<1_000: return "\(megabits) Mb/s"
        case 1_000: return "1 Gb/s"
        case 10_000: return "10 Gb/s"
        default: return String(format: "%.1f Gb/s", Double(Float(megabits) / 1_000))
        }
    }

    /// D134: iStat's speed for the row: a zero `IOLinkSpeed` takes the
    /// number before "baseT" when the media subtype ends with it
    /// ("1000baseT" is 1000; `integerValue`, so "10GbaseT" is 10); any other
    /// speed is kept.
    static func displayedLinkSpeed(_ megabits: Int, mediaSubType: String?) -> Int {
        guard megabits == 0, let mediaSubType, mediaSubType.hasSuffix("baseT") else { return megabits }
        return (mediaSubType.replacingOccurrences(of: "baseT", with: "") as NSString).integerValue
    }

    /// D134: the media options in the system's order, iStat's labels for full
    /// duplex, half duplex and flow control, any other option as the system
    /// names it (before: a duplex text matched by substrings, never read).
    static func mediaOptions(_ options: [String]) -> [String] {
        options.map { option in
            switch option {
            case "full-duplex": L10n.text("全双工", "Full Duplex")
            case "half-duplex": L10n.text("半双工", "Half Duplex")
            case "flow-control": L10n.text("流控制", "Flow Control")
            default: option
            }
        }
    }

    /// The Wi-Fi rows in iStat's order, formats and conditions: the network
    /// and BSSID when known; the transmit rate when not 0; RSSI and noise
    /// each when not 0; the mode, SNR and channel only with both readings
    /// (associated). The mode carries its band ("802.11ax (5GHz)", "N/A"
    /// without a mode), SNR is RSSI − noise, the channel its width as iStat
    /// writes it ("149 (80 Mhz)").
    static func wiFiRows(_ wifi: WiFiConnectionDetails) -> [Row] {
        var rows: [Row] = []
        let rssi = wifi.rssiDBm ?? 0
        let noise = wifi.noiseDBm ?? 0
        let isAssociated = rssi != 0 && noise != 0
        if let ssid = meaningful(wifi.ssid) {
            rows.append(Row(title: L10n.text("网络", "Network"), value: ssid))
        }
        if let bssid = meaningful(wifi.bssid) {
            rows.append(Row(title: "BSSID", value: bssid))
        }
        if isAssociated {
            let mode = meaningful(wifi.phyMode) ?? "N/A"
            let band = wifi.bandGHz.flatMap(bandText)
            rows.append(Row(title: L10n.text("模式", "Mode"), value: band.map { "\(mode) (\($0))" } ?? mode))
        }
        if let rate = wifi.transmitRateMbps, rate.isFinite, rate != 0 {
            rows.append(Row(title: L10n.text("传输速率", "Transmit Rate"), value: String(format: "%.0f", rate) + " Mbps"))
        }
        if rssi != 0 {
            rows.append(Row(title: "RSSI", value: "\(rssi) dBm"))
        }
        if noise != 0 {
            rows.append(Row(title: L10n.text("噪音", "Noise"), value: "\(noise) dBm"))
        }
        if isAssociated {
            rows.append(Row(title: "SNR", value: "\(rssi - noise) dB"))
            if let channel = wifi.channelNumber {
                let width = wifi.channelWidthMHz.flatMap { [20, 40, 80, 160].contains($0) ? " (\($0) Mhz)" : nil } ?? ""
                rows.append(Row(title: L10n.text("频段", "Channel"), value: "\(channel)\(width)"))
            }
        }
        return rows
    }

    static func bandText(_ gigahertz: Int) -> String? {
        switch gigahertz {
        case 2: "2.4GHz"
        case 5: "5GHz"
        case 6: "6GHz"
        default: nil
        }
    }

    private static func meaningful(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func meaningful(_ values: [String]) -> [String] {
        values.compactMap { meaningful($0) }
    }
}

/// D125: the Wi-Fi section's switch is the text section's (was the native
/// mini switch); turning Wi-Fi off still asks first.
private struct GeekWiFiPowerControl: View {
    let powerState: WiFiPowerState
    @ObservedObject var coordinator: WiFiPowerControlCoordinator
    @State private var isConfirmingPowerOff = false

    var body: some View {
        Group {
            if let isPoweredOn = displayedPower {
                ZStack {
                    Toggle(isOn: powerBinding(isPoweredOn: isPoweredOn)) { EmptyView() }
                        .toggleStyle(GeekIStatSwitchToggleStyle())
                        .disabled(powerState == .unavailable)
                        .accessibilityLabel(isPoweredOn
                            ? L10n.text("Wi-Fi 当前已开启", "Wi-Fi is currently on")
                            : L10n.text("Wi-Fi 当前已关闭", "Wi-Fi is currently off"))
                        .accessibilityHint(isPoweredOn
                            ? L10n.text("关闭后会断开当前无线连接，需要确认", "Turning off requires confirmation and disconnects the current wireless connection")
                            : L10n.text("开启无线网络接口", "Turns on the wireless interface"))

                    if coordinator.isApplying {
                        ProgressView()
                            .controlSize(.mini)
                            .allowsHitTesting(false)
                            .accessibilityLabel(L10n.text(
                                "正在更改 Wi-Fi 状态",
                                "Changing Wi-Fi state"
                            ))
                    }
                }
            } else {
                Text("—")
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text(
                        "Wi-Fi 控制不可用",
                        "Wi-Fi control unavailable"
                    ))
            }
        }
        .confirmationDialog(
            L10n.text("关闭 Wi-Fi？", "Turn Off Wi-Fi?"),
            isPresented: $isConfirmingPowerOff,
            titleVisibility: .visible
        ) {
            Button(L10n.text("关闭 Wi-Fi", "Turn Off Wi-Fi"), role: .destructive) {
                coordinator.request(false)
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "这会立即断开当前无线连接。",
                "This immediately disconnects the current wireless connection."
            ))
        }
    }

    private var displayedPower: Bool? {
        guard powerState != .unavailable else { return nil }
        let fallback: Bool? = switch powerState {
        case .onConnected, .onDisconnected, .changingToOn:
            true
        case .off, .changingToOff:
            false
        case .unavailable:
            nil
        }
        return coordinator.displayedPower(fallback: fallback)
    }

    private func powerBinding(isPoweredOn: Bool) -> Binding<Bool> {
        Binding(
            get: { coordinator.displayedPower(fallback: isPoweredOn) ?? isPoweredOn },
            set: { nextValue in
                if nextValue {
                    coordinator.request(true)
                } else {
                    isConfirmingPowerOff = true
                }
            }
        )
    }
}
