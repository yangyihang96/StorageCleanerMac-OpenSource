import SwiftUI

struct MenuBarNetworkPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var networkPage: some View {
        MenuBarNetworkPanel {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    AdvancedMetricTile(
                        title: L10n.text("下载", "Download"),
                        value: networkDownText,
                        detail: L10n.text("当前速率", "Current"),
                        tint: resolvedDownloadTint,
                        progress: networkRelativeProgress(direction: .download)
                    )
                    AdvancedMetricTile(
                        title: L10n.text("上传", "Upload"),
                        value: networkUpText,
                        detail: L10n.text("当前速率", "Current"),
                        tint: resolvedUploadTint,
                        progress: networkRelativeProgress(direction: .upload)
                    )
                }

                AdvancedPanelCard(
                    title: L10n.text("实时带宽", "Live Bandwidth"),
                    systemImage: AppSymbols.Monitor.network,
                    tint: resolvedDownloadTint
                ) {
                    GeekPrecisionNetworkChart(
                        points: history,
                        accessibilityLabel: L10n.text("最近两分钟网络上下行逐点采样图", "Per-sample upload and download activity over the last two minutes")
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)
                }

                AdvancedPanelCard(
                    title: L10n.text("最近 2 分钟", "Last 2 Minutes"),
                    systemImage: AppSymbols.Panel.historyWindow,
                    tint: AppDesignTokens.Palette.secondary
                ) {
                    AdvancedValueRow(title: L10n.text("下载平均", "Download Average"), value: rateText(geekNetworkDownAverage), tint: resolvedDownloadTint)
                    AdvancedValueRow(title: L10n.text("下载峰值", "Download Peak"), value: rateText(networkDownPeak), tint: resolvedDownloadTint)
                    AdvancedValueRow(title: L10n.text("上传平均", "Upload Average"), value: rateText(geekNetworkUpAverage), tint: resolvedUploadTint)
                    AdvancedValueRow(title: L10n.text("上传峰值", "Upload Peak"), value: rateText(networkUpPeak), tint: resolvedUploadTint)
                    AdvancedValueRow(title: L10n.text("估算下载量", "Estimated Download"), value: ByteFormat.string(sessionDownloadedBytes), tint: resolvedDownloadTint)
                    AdvancedValueRow(title: L10n.text("估算上传量", "Estimated Upload"), value: ByteFormat.string(sessionUploadedBytes), tint: resolvedUploadTint)
                }

                AdvancedPanelCard(
                    title: L10n.text("原生网络接口", "Native Network Interface"),
                    systemImage: AppSymbols.Panel.wifi,
                    tint: AppDesignTokens.Palette.secondary
                ) {
                    if let interface = networkInterfaceSnapshot {
                        AdvancedValueRow(title: L10n.text("BSD 接口", "BSD Interface"), value: interface.interfaceName ?? "--", tint: AppDesignTokens.Palette.information)
                        if let hardwareAddress = interface.hardwareAddress {
                            AdvancedValueRow(title: "MAC Address", value: hardwareAddress, tint: AppDesignTokens.Palette.secondary)
                        }
                        if let ssid = interface.ssid {
                            AdvancedValueRow(title: "Wi-Fi", value: ssid, tint: AppDesignTokens.Palette.tertiary)
                        }
                        if let rate = interface.transmitRateMbps {
                            AdvancedValueRow(title: "Transmit Rate", value: String(format: "%.0f Mbps", rate), tint: AppDesignTokens.Palette.tertiary)
                        }
                        if let rssi = interface.rssiDBm {
                            AdvancedValueRow(title: "RSSI", value: "\(rssi) dBm", tint: rssi >= -67 ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)
                        }
                        if let noise = interface.noiseDBm {
                            AdvancedValueRow(title: "Noise", value: "\(noise) dBm", tint: AppDesignTokens.Palette.secondary)
                        }
                        if let snr = interface.signalToNoiseDB {
                            AdvancedValueRow(title: "SNR", value: "\(snr) dB", tint: snr >= 25 ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)
                        }
                        if let channel = interface.channelNumber {
                            let width = interface.channelWidthMHz.map { " (\($0) MHz)" } ?? ""
                            AdvancedValueRow(title: "Channel", value: "\(channel)\(width)", tint: AppDesignTokens.Palette.secondary)
                        }
                        if !interface.ipv4Addresses.isEmpty {
                            AdvancedValueRow(title: "IPv4", value: interface.ipv4Addresses.joined(separator: " · "), tint: AppDesignTokens.Palette.information)
                        }
                        if let subnetMask = interface.ipv4SubnetMask {
                            AdvancedValueRow(title: L10n.text("子网掩码", "Subnet Mask"), value: subnetMask, tint: AppDesignTokens.Palette.secondary)
                        }
                        if let router = interface.ipv4Router {
                            AdvancedValueRow(title: L10n.text("IPv4 路由", "IPv4 Router"), value: router, tint: AppDesignTokens.Palette.secondary)
                        }
                        if !interface.ipv6Addresses.isEmpty {
                            AdvancedValueRow(title: "IPv6", value: interface.ipv6Addresses.joined(separator: " · "), tint: AppDesignTokens.Palette.secondary)
                        }
                        if let router = interface.ipv6Router {
                            AdvancedValueRow(title: L10n.text("IPv6 路由", "IPv6 Router"), value: router, tint: AppDesignTokens.Palette.secondary)
                        }
                        if !interface.dnsServers.isEmpty {
                            AdvancedValueRow(title: "DNS", value: interface.dnsServers.joined(separator: " · "), tint: AppDesignTokens.Palette.tertiary)
                        }
                        if interface.interfaceName == nil {
                            AdvancedUnavailableRow(title: L10n.text("未读取到活动网络接口", "No active network interface available"))
                        }
                    } else {
                        AdvancedUnavailableRow(title: L10n.text("正在读取网络接口", "Reading network interface"))
                    }
                }

                if hasCachedNetworkSpeedTest {
                    AdvancedPanelCard(
                        title: L10n.text("上次手动测速", "Last Manual Speed Test"),
                        systemImage: AppSymbols.Panel.speed,
                        tint: AppDesignTokens.Palette.secondary
                    ) {
                        if let download = healthSummary?.lastDownloadMbps {
                            AdvancedValueRow(
                                title: L10n.text("下载", "Download"),
                                value: speedMbpsText(download),
                                tint: resolvedDownloadTint
                            )
                        }
                        if let upload = healthSummary?.lastUploadMbps {
                            AdvancedValueRow(
                                title: L10n.text("上传", "Upload"),
                                value: speedMbpsText(upload),
                                tint: resolvedUploadTint
                            )
                        }
                        if let testedAt = healthSummary?.lastSpeedTestAt {
                            AdvancedValueRow(
                                title: L10n.text("测速时间", "Tested At"),
                                value: timestampText(testedAt),
                                tint: .secondary
                            )
                        }
                    }
                }
            }
        }
        }

}
