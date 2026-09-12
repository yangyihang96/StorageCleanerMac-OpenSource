import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekNetworkPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            geekNetworkTrend
            if let tunnel = networkTopologySnapshot?.activeVPNTunnel {
                GeekVPNDisclosure(tunnel: tunnel, refresh: refreshPanelData)
            }
            geekPhysicalNetwork
            geekNetworkPublicAddress
            geekNetworkLocalAddresses
            geekNetworkProcessCard
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var geekNetworkTrend: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("网络活动历史三级详情", "Network Activity History Deep Detail"),
            chartRangeMetric: .network,
            popoverSize: GeekHoverDetailMetrics.compactHistorySize
        ) {
            geekNetworkTrendCard
        } detail: {
            GeekNetworkHistoryHoverDetail(
                points: geekChartHistory,
                duration: geekChartDuration,
                uploadValue: networkUpText,
                downloadValue: networkDownText
            )
        }
    }

    private var geekNetworkTrendCard: some View {
        GeekCombinedCard(height: 150) {
            VStack(spacing: 3) {
                HStack(spacing: 12) {
                    GeekLiveNetworkValue(
                        title: L10n.text("上传", "Upload"),
                        value: networkUpText,
                        tint: resolvedUploadTint
                    )
                    GeekLiveNetworkValue(
                        title: L10n.text("下载", "Download"),
                        value: networkDownText,
                        tint: resolvedDownloadTint
                    )
                }

                GeekPrecisionNetworkChart(
                    points: geekChartHistory,
                    accessibilityLabel: L10n.text(
                        "最近 \(geekChartRangeTitle) 的网络上传与下载趋势",
                        "Network upload and download trends over the last \(geekChartRangeTitle)"
                    ),
                    duration: geekChartDuration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    horizontalInset: 0
                )
                .frame(height: 72)

                HStack(spacing: 10) {
                    GeekNetworkPeakAndTotalValue(
                        direction: "↑",
                        peak: rateText(geekNetworkUpPeak),
                        total: ByteFormat.string(sessionUploadedBytes),
                        color: resolvedUploadTint,
                        accessibilityLabel: L10n.text(
                            "上传峰值 \(rateText(geekNetworkUpPeak))，会话累计 \(ByteFormat.string(sessionUploadedBytes))",
                            "Upload peak \(rateText(geekNetworkUpPeak)), session total \(ByteFormat.string(sessionUploadedBytes))"
                        )
                    )
                    GeekNetworkPeakAndTotalValue(
                        direction: "↓",
                        peak: rateText(geekNetworkDownPeak),
                        total: ByteFormat.string(sessionDownloadedBytes),
                        color: resolvedDownloadTint,
                        accessibilityLabel: L10n.text(
                            "下载峰值 \(rateText(geekNetworkDownPeak))，会话累计 \(ByteFormat.string(sessionDownloadedBytes))",
                            "Download peak \(rateText(geekNetworkDownPeak)), session total \(ByteFormat.string(sessionDownloadedBytes))"
                        )
                    )
                }
            }
        }
    }

    private var geekNetworkPublicAddress: some View {
        GeekNetworkAddressCard(
            title: L10n.text("公共 IP 地址", "Public IP Addresses"),
            ipv4Address: publicNetworkAddressSnapshot?.ipv4Address,
            ipv6Address: publicNetworkAddressSnapshot?.ipv6Address,
            ipv4CountryCode: publicNetworkAddressSnapshot?.ipv4CountryCode,
            ipv6CountryCode: publicNetworkAddressSnapshot?.ipv6CountryCode,
            isLoading: isRefreshingPublicNetworkAddress,
            unavailableText: L10n.text("暂不可用", "Unavailable")
        )
        .accessibilityHint(L10n.text(
            "极客概览显示网络模块时预取公网地址，成功结果缓存 15 分钟。",
            "Public addresses are prefetched while the Network module is visible in Geek Overview and successful results are cached for 15 minutes."
        ))
    }

    private var geekNetworkLocalAddresses: some View {
        GeekNetworkAddressCard(
            title: L10n.text("本地 IP 地址", "IP Addresses"),
            ipv4Address: geekPhysicalIPv4Address,
            ipv6Address: geekPhysicalIPv6Address,
            ipv4CountryCode: nil,
            ipv6CountryCode: nil,
            isLoading: networkTopologySnapshot == nil && networkInterfaceSnapshot == nil,
            unavailableText: "—"
        )
    }

    private var geekPhysicalNetwork: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "连接方式，\(geekPhysicalNetworkTitle)，\(geekPhysicalNetworkDetail)，显示详情",
                "Connection, \(geekPhysicalNetworkTitle), \(geekPhysicalNetworkDetail), show details"
            ),
            popoverSize: GeekNetworkTertiaryView.referenceSize
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

    private var geekNetworkProcessCard: some View {
        GeekCombinedCard(height: geekNetworkProcessCardHeight, verticalPadding: 5) {
            VStack(spacing: 1) {
                GeekNetworkProcessHeader()
                geekNetworkProcessRows
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var geekNetworkProcessCardHeight: CGFloat {
        guard !displayedNetworkProcesses.isEmpty else { return 43 }
        return showsExtendedGeekDetails ? 92 : 60
    }

    @ViewBuilder
    private var geekNetworkProcessRows: some View {
        if !displayedNetworkProcesses.isEmpty {
            ForEach(displayedNetworkProcesses) { process in
                GeekNetworkProcessRow(process: process)
            }
        } else {
            HStack(spacing: 5) {
                if networkProcessSamplingState == .sampling
                    || networkProcessSamplingState == .idle {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(geekNetworkProcessStatusText)
            }
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .accessibilityLabel(geekNetworkProcessStatusAccessibilityText)
        }
    }

    private var displayedNetworkProcesses: [NativeNetworkProcessTransfer] {
        guard let snapshot = networkProcessSnapshot else { return [] }
        let limit = showsExtendedGeekDetails ? 4 : 2
        return Array(snapshot.processes.prefix(limit))
    }

    private var geekNetworkProcessStatusText: String {
        switch networkProcessSamplingState {
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
        switch networkProcessSamplingState {
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
            return L10n.text("正在读取物理网络…", "Reading physical network…")
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
    var body: some View {
        HStack(spacing: 4) {
            Text(L10n.text("进程", "Processes"))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Text("↑")
                .foregroundStyle(MenuBarNetworkPalette.upload)
                .frame(width: 48, alignment: .trailing)
                .accessibilityLabel(L10n.text("上传速率", "Upload rate"))

            Text("↓")
                .foregroundStyle(MenuBarNetworkPalette.download)
                .frame(width: 48, alignment: .trailing)
                .accessibilityLabel(L10n.text("下载速率", "Download rate"))
        }
        .font(.system(size: 10, weight: .medium))
        .frame(height: 14)
    }
}

private struct GeekNetworkProcessRow: View {
    let process: NativeNetworkProcessTransfer

    var body: some View {
        HStack(spacing: 5) {
            AdvancedAppIcon(path: process.iconPath, fallback: "app.fill")
                .scaleEffect(0.67)
                .frame(width: 16, height: 16)

            Text(process.name)
                .font(.system(size: 10, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 3)

            Text(ByteFormat.string(process.uploadBytesPerSecond))
                .frame(width: 48, alignment: .trailing)

            Text(ByteFormat.string(process.downloadBytesPerSecond))
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .regular))
        .monospacedDigit()
        .frame(height: 16)
        .help(L10n.text(
            "\(process.name)：上传 \(ByteFormat.string(process.uploadBytesPerSecond))/s，下载 \(ByteFormat.string(process.downloadBytesPerSecond))/s",
            "\(process.name): upload \(ByteFormat.string(process.uploadBytesPerSecond))/s, download \(ByteFormat.string(process.downloadBytesPerSecond))/s"
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(process.name)
        .accessibilityValue(L10n.text(
            "上传 \(ByteFormat.string(process.uploadBytesPerSecond)) 每秒，下载 \(ByteFormat.string(process.downloadBytesPerSecond)) 每秒",
            "Upload \(ByteFormat.string(process.uploadBytesPerSecond)) per second, download \(ByteFormat.string(process.downloadBytesPerSecond)) per second"
        ))
    }
}

private struct GeekNetworkPeakAndTotalValue: View {
    let direction: String
    let peak: String
    let total: String
    let color: Color
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 3) {
            Text(direction)
                .foregroundStyle(color)
            Text(peak)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(total)
        }
        .font(.system(size: 10, weight: .regular))
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct GeekNetworkAddressCard: View {
    let title: String
    let ipv4Address: String?
    let ipv6Address: String?
    let ipv4CountryCode: String?
    let ipv6CountryCode: String?
    let isLoading: Bool
    let unavailableText: String

    private var showsIPv6: Bool {
        isLoading || !(ipv6Address?.isEmpty ?? true)
    }

    var body: some View {
        GeekCombinedCard(height: showsIPv6 ? 57 : 39, verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)

                GeekNetworkAddressLine(
                    version: "IPv4",
                    value: addressText(ipv4Address, countryCode: ipv4CountryCode)
                )
                if showsIPv6 {
                    GeekNetworkAddressLine(
                        version: "IPv6",
                        value: addressText(ipv6Address, countryCode: ipv6CountryCode)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func addressText(_ address: String?, countryCode: String?) -> String {
        if let address, !address.isEmpty {
            guard let flag = PublicNetworkAddressService.flagEmoji(
                forCountryCode: countryCode
            ) else {
                return address
            }
            return "\(flag)  \(address)"
        }
        return isLoading ? L10n.text("正在读取…", "Reading…") : unavailableText
    }
}

private struct GeekNetworkAddressLine: View {
    let version: String
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 12, weight: .regular))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
            .accessibilityLabel("\(version), \(value)")
    }
}

private struct GeekNetworkTopologyRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let accessibilityLabel: String
    var showsDisclosure = false

    var body: some View {
        GeekCombinedCard(height: 31, verticalPadding: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 15)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct GeekVPNHoverDetail: View {
    private static let maximumVisibleDNSRows = 3

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

    static func preferredSize(for tunnel: VPNTunnelSnapshot) -> CGSize {
        let detailRows = tunnelDetailRowCount(for: tunnel)
        let tunnelCardHeight = max(56, CGFloat(detailRows + 1) * 15 + 12)
        let managementCardHeight: CGFloat = 64
        let contentHeight = 46 + tunnelCardHeight + managementCardHeight
        let spacing = GeekPanelLayout.detailSpacing * 2
        let padding = GeekPanelLayout.contentPadding * 2
        return CGSize(
            width: GeekHoverDetailMetrics.vpnWidth,
            height: contentHeight + spacing + padding
        )
    }

    var body: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            statusCard
            tunnelCard
            managementCard
        }
        .padding(GeekPanelLayout.contentPadding)
        .frame(
            width: preferredSize.width,
            height: preferredSize.height,
            alignment: .top
        )
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

    private var statusCard: some View {
        GeekCombinedCard(height: 46, verticalPadding: 5) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(vpnStatusTint(tunnel.status))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tunnel.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(vpnStatusText(tunnel.status))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(vpnStatusTint(tunnel.status))
                }

                Spacer(minLength: 4)

                Text(tunnel.protocolKind.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var tunnelCard: some View {
        GeekCombinedCard(height: tunnelCardHeight, verticalPadding: 5) {
            VStack(spacing: 1) {
                GeekNetworkTertiaryHeader(title: L10n.text("VPN 详情", "VPN Details"))
                GeekNetworkCompactRow(title: L10n.text("协议", "Protocol"), value: tunnel.protocolKind.displayName)
                GeekNetworkCompactRow(title: "BSD", value: tunnel.bsdName)
                if let tunnelIPv4 {
                    GeekNetworkCompactRow(
                        title: L10n.text("隧道 IPv4", "Tunnel IPv4"),
                        value: tunnelIPv4
                    )
                }
                if let tunnelIPv6 {
                    GeekNetworkCompactRow(
                        title: L10n.text("隧道 IPv6", "Tunnel IPv6"),
                        value: tunnelIPv6
                    )
                }
                ForEach(Array(displayedScopedDNSServers.enumerated()), id: \.offset) { index, server in
                    GeekNetworkCompactRow(title: index == 0 ? "DNS" : "", value: server)
                }
                if additionalScopedDNSCount > 0 {
                    GeekNetworkCompactRow(
                        title: "DNS",
                        value: L10n.text(
                            "另有 \(additionalScopedDNSCount) 条 DNS",
                            "\(additionalScopedDNSCount) more DNS servers"
                        )
                    )
                }
                if let remote = tunnel.gatewayOrRemoteAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !remote.isEmpty {
                    GeekNetworkCompactRow(title: L10n.text("远端", "Remote"), value: remote)
                }
            }
        }
    }

    private var preferredSize: CGSize {
        Self.preferredSize(for: tunnel)
    }

    private var tunnelCardHeight: CGFloat {
        max(56, CGFloat(tunnelDetailRowCount + 1) * 15 + 12)
    }

    private var tunnelDetailRowCount: Int {
        Self.tunnelDetailRowCount(for: tunnel)
    }

    private var tunnelIPv4: String? {
        Self.meaningfulValues(tunnel.tunnelIPv4).first
    }

    private var tunnelIPv6: String? {
        Self.meaningfulValues(tunnel.tunnelIPv6).first
    }

    private var displayedScopedDNSServers: [String] {
        Array(Self.meaningfulValues(tunnel.scopedDNSServers).prefix(Self.maximumVisibleDNSRows))
    }

    private var additionalScopedDNSCount: Int {
        max(0, Self.meaningfulValues(tunnel.scopedDNSServers).count - displayedScopedDNSServers.count)
    }

    private static func tunnelDetailRowCount(for tunnel: VPNTunnelSnapshot) -> Int {
        let dnsServers = meaningfulValues(tunnel.scopedDNSServers)
        let addressRows = meaningfulValues(tunnel.tunnelIPv4).isEmpty ? 0 : 1
        let ipv6Rows = meaningfulValues(tunnel.tunnelIPv6).isEmpty ? 0 : 1
        let shownDNSRows = min(dnsServers.count, maximumVisibleDNSRows)
        let remainingDNSRow = dnsServers.count > maximumVisibleDNSRows ? 1 : 0
        let remoteRow = tunnel.gatewayOrRemoteAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1 : 0
        return 2 + addressRows + ipv6Rows + shownDNSRows + remainingDNSRow + remoteRow
    }

    private static func meaningfulValues(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var managementCard: some View {
        GeekCombinedCard(height: 64, verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 4) {
                Text(managementDescription)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let actionTitle = actionTitle {
                    HStack(spacing: 6) {
                        Button(actionTitle) {
                            requestAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isPerformingAction || !preflight.canExecute)

                        if isPerformingAction {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel(L10n.text("正在请求 VPN 操作", "Requesting VPN action"))
                        }
                    }
                }

                if let actionMessage {
                    Text(actionMessage)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var actionTitle: String? {
        guard preflight.canExecute else { return nil }
        switch preflight.capability {
        case .systemConfigurationConnection:
            return L10n.text("断开连接", "Disconnect")
        case .openProviderApplication:
            return L10n.text("打开 VPN 应用", "Open VPN App")
        case .openSystemSettingsOnly:
            return L10n.text("打开系统设置", "Open System Settings")
        case .ownedNEVPNConnection, .readOnly, .unsupported:
            return nil
        }
    }

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

struct GeekNetworkTertiaryView: View {
    static let referenceSize = CGSize(width: 255, height: 419)

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

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: GeekPanelLayout.detailSpacing) {
                interfaceCard
                if connection.wifi != nil,
                   connection.connectionKind == .wifi
                    || connection.connectionKind == .disconnected {
                    wiFiCard
                } else if connection.ethernet != nil {
                    ethernetCard
                }
                ipAddressCard
                ipv4Card
                ipv6Card
            }
            .padding(contentPadding)
        }
        .scrollIndicators(.automatic)
        .frame(width: Self.referenceSize.width, height: Self.referenceSize.height, alignment: .top)
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

    private var interfaceCard: some View {
        GeekCombinedCard(height: connection.isVPNActive ? 91 : 76, verticalPadding: 5) {
            VStack(spacing: 1) {
                GeekNetworkTertiaryHeader(title: L10n.text("网络接口", "Interface"))
                GeekNetworkCompactRow(title: L10n.text("类型", "Type"), value: connectionTypeText)
                GeekNetworkCompactRow(title: L10n.text("BSD 名称", "BSD Name"), value: connection.activeInterface?.bsdName ?? "—")
                hardwareAddressRow
                if connection.isVPNActive {
                    GeekNetworkCompactRow(title: "VPN", value: L10n.text("已连接", "Connected"))
                }
            }
        }
    }

    private var hardwareAddressRow: some View {
        ViewThatFits(in: .horizontal) {
            hardwareAddressLine
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("MAC 地址", "MAC Address"))
                    .foregroundStyle(.secondary)
                hardwareAddressValue
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.system(size: 12, weight: .regular))
    }

    private var hardwareAddressLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(L10n.text("MAC 地址", "MAC Address"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            hardwareAddressValue
        }
    }

    private var hardwareAddressValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayedHardwareAddress)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if connection.activeInterface?.hardwareAddress != nil {
                Button(revealsHardwareAddress
                    ? L10n.text("隐藏", "Hide")
                    : L10n.text("显示", "Show")) {
                    revealsHardwareAddress.toggle()
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .font(.system(size: 10, weight: .medium))
                .fixedSize()
                .accessibilityLabel(revealsHardwareAddress
                    ? L10n.text("隐藏 MAC 地址", "Hide MAC address")
                    : L10n.text("显示 MAC 地址", "Show MAC address"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var wiFiCard: some View {
        GeekCombinedCard(height: 146, verticalPadding: 5) {
            VStack(spacing: 1) {
                ViewThatFits(in: .horizontal) {
                    wiFiHeader
                    VStack(alignment: .leading, spacing: 0) {
                        GeekNetworkTertiaryHeader(title: "Wi-Fi")
                        wiFiHeaderStatus
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                GeekNetworkCompactRow(title: L10n.text("网络名称", "Network Name"), value: wiFiNetworkName)
                GeekNetworkCompactRow(title: L10n.text("模式", "Mode"), value: connection.wifi?.phyMode ?? "—")
                GeekNetworkCompactRow(title: L10n.text("频段", "Band"), value: wiFiBandText)
                GeekNetworkCompactRow(
                    title: L10n.text("传输速率", "Transmit Rate"),
                    value: connection.wifi?.transmitRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "—"
                )
                GeekNetworkCompactRow(
                    title: "RSSI",
                    value: connection.wifi?.rssiDBm.map { "\($0) dBm" } ?? "—"
                )
                GeekNetworkCompactRow(
                    title: L10n.text("噪声", "Noise"),
                    value: connection.wifi?.noiseDBm.map { "\($0) dBm" } ?? "—"
                )
                GeekNetworkCompactRow(
                    title: L10n.text("信噪比", "SNR"),
                    value: connection.wifi?.snrDB.map { "\($0) dB" } ?? "—"
                )
                GeekNetworkCompactRow(title: L10n.text("频道", "Channel"), value: channelText)
            }
        }
    }

    private var wiFiHeader: some View {
        HStack(spacing: 8) {
            GeekNetworkTertiaryHeader(title: "Wi-Fi")
            Spacer(minLength: 8)
            wiFiHeaderStatus
        }
    }

    private var wiFiHeaderStatus: some View {
        HStack(spacing: 8) {
            Text(wiFiPowerStatusText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(wiFiPowerStatusTint)
                .lineLimit(1)
                .help(wiFiPowerHelpText)
            GeekWiFiPowerControl(
                powerState: displayedWiFiPowerState,
                coordinator: wiFiPowerControl
            )
            .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var ethernetCard: some View {
        GeekCombinedCard(height: 91, verticalPadding: 5) {
            VStack(spacing: 1) {
                GeekNetworkTertiaryHeader(title: L10n.text("有线网络", "Ethernet"))
                GeekNetworkCompactRow(
                    title: L10n.text("状态", "Status"),
                    value: connection.ethernet?.linkActive == true
                        ? L10n.text("已连接", "Connected")
                        : L10n.text("未连接", "Disconnected")
                )
                GeekNetworkCompactRow(
                    title: L10n.text("链路速率", "Link Speed"),
                    value: ethernetLinkSpeedText
                )
                GeekNetworkCompactRow(
                    title: L10n.text("双工模式", "Duplex"),
                    value: connection.ethernet?.duplex ?? "—"
                )
                GeekNetworkCompactRow(
                    title: "MTU",
                    value: connection.ethernet?.mtu.map { $0.formatted() } ?? "—"
                )
                GeekNetworkCompactRow(
                    title: L10n.text("介质类型", "Media Type"),
                    value: connection.ethernet?.mediaSubtype ?? "—"
                )
            }
        }
    }

    private var ipAddressCard: some View {
        GeekCombinedCard(height: addressCardHeight, verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 1) {
                GeekNetworkTertiaryHeader(title: L10n.text("本地 IP 地址", "IP Addresses"))
                ForEach(Array(addressRows.enumerated()), id: \.offset) { _, row in
                    GeekNetworkInspectorAddressRow(title: row.0, value: row.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ipv4Card: some View {
        GeekCombinedCard(height: configurationCardHeight(ipv4Rows), verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 1) {
                GeekNetworkTertiaryHeader(title: "IPv4")
                ForEach(Array(ipv4Rows.enumerated()), id: \.offset) { _, row in
                    GeekNetworkInspectorAddressRow(title: row.0, value: row.1)
                }
            }
        }
    }

    private var ipv6Card: some View {
        GeekCombinedCard(height: configurationCardHeight(ipv6Rows), verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 1) {
                GeekNetworkTertiaryHeader(title: "IPv6")
                ForEach(Array(ipv6Rows.enumerated()), id: \.offset) { _, row in
                    GeekNetworkInspectorAddressRow(title: row.0, value: row.1)
                }
            }
        }
    }

    private var connection: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(native: snapshot, topology: topology)
    }

    private var connectionTypeText: String {
        switch connection.connectionKind {
        case .wifi:
            "Wi-Fi"
        case .ethernet:
            L10n.text("有线网络", "Ethernet")
        case .other:
            connection.activeInterface?.displayName ?? L10n.text("其他网络", "Other Network")
        case .disconnected:
            connection.wifi == nil ? L10n.text("未连接", "Disconnected") : "Wi-Fi"
        }
    }

    private var displayedHardwareAddress: String {
        guard let address = connection.activeInterface?.hardwareAddress?.uppercased() else {
            return "—"
        }
        guard !revealsHardwareAddress else { return address }
        let components = address.split(separator: ":").map(String.init)
        guard components.count >= 2 else { return "••:••:••:••:••:••" }
        return "••:••:••:••:\(components.suffix(2).joined(separator: ":"))"
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

    private var wiFiPowerStatusTint: Color {
        if wiFiPowerControl.lastError != nil { return AppDesignTokens.Palette.warning }
        return switch displayedWiFiPowerState {
        case .onConnected:
            AppDesignTokens.Palette.success
        case .changingToOn, .changingToOff:
            AppDesignTokens.Palette.warning
        case .onDisconnected, .off, .unavailable:
            .secondary
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

    private var wiFiNetworkName: String {
        if let ssid = connection.wifi?.ssid, !ssid.isEmpty { return ssid }
        return displayedWiFiPowerState == .onConnected
            ? L10n.text("不可用", "Unavailable")
            : "—"
    }

    private var wiFiBandText: String {
        connection.wifi?.bandGHz.map { "\($0) GHz" } ?? "—"
    }

    private var channelText: String {
        guard let channel = connection.wifi?.channelNumber else { return "—" }
        guard let width = connection.wifi?.channelWidthMHz else { return "\(channel)" }
        return "\(channel) (\(width) MHz)"
    }

    private var ethernetLinkSpeedText: String {
        guard let speed = connection.ethernet?.linkSpeedMbps, speed > 0 else { return "—" }
        if speed >= 1_000 {
            return speed.isMultiple(of: 1_000)
                ? "\(speed / 1_000) Gbps"
                : String(format: "%.1f Gbps", Double(speed) / 1_000)
        }
        return "\(speed) Mbps"
    }

    private var addressRows: [(String, String)] {
        let ipv4 = connection.ipConfiguration.ipv4Addresses.enumerated().map {
            ($0.offset == 0 ? "IPv4" : "", $0.element)
        }
        let ipv6 = connection.ipConfiguration.ipv6Addresses.enumerated().map {
            ($0.offset == 0 ? "IPv6" : "", $0.element)
        }
        let rows = ipv4 + ipv6
        return rows.isEmpty
            ? [(L10n.text("状态", "Status"), L10n.text("未配置", "Not Configured"))]
            : rows
    }

    private var ipv4Rows: [(String, String)] {
        var rows = connection.ipConfiguration.subnetMasks.enumerated().map {
            ($0.offset == 0 ? L10n.text("子网掩码", "Subnet Mask") : "", $0.element)
        }
        if let router = connection.ipConfiguration.ipv4Router {
            rows.append((L10n.text("路由器", "Router"), router))
        }
        rows += connection.ipConfiguration.dnsServers
            .filter { !$0.contains(":") }
            .enumerated()
            .map { ($0.offset == 0 ? "DNS" : "", $0.element) }
        return rows.isEmpty
            ? [(L10n.text("状态", "Status"), L10n.text("未配置", "Not Configured"))]
            : rows
    }

    private var ipv6Rows: [(String, String)] {
        var rows: [(String, String)] = []
        if let router = connection.ipConfiguration.ipv6Router {
            rows.append((L10n.text("路由器", "Router"), router))
        }
        rows += connection.ipConfiguration.dnsServers
            .filter { $0.contains(":") }
            .enumerated()
            .map { ($0.offset == 0 ? "DNS" : "", $0.element) }
        return rows.isEmpty
            ? [(L10n.text("状态", "Status"), L10n.text("未配置", "Not Configured"))]
            : rows
    }

    private var addressCardHeight: CGFloat {
        max(44, 24 + CGFloat(addressRows.count) * 17)
    }

    private func configurationCardHeight(_ rows: [(String, String)]) -> CGFloat {
        max(44, 24 + CGFloat(rows.count) * 17)
    }
}

private struct GeekNetworkTertiaryHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct GeekNetworkInspectorAddressRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: title.isEmpty ? 0 : 4)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? value : "\(title), \(value)")
    }
}

private struct GeekNetworkCompactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .regular))
        .help(value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct GeekWiFiPowerControl: View {
    let powerState: WiFiPowerState
    @ObservedObject var coordinator: WiFiPowerControlCoordinator
    @State private var isConfirmingPowerOff = false

    var body: some View {
        Group {
            if let isPoweredOn = displayedPower {
                ZStack {
                    Toggle("", isOn: powerBinding(isPoweredOn: isPoweredOn))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
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
                    .font(.caption)
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
