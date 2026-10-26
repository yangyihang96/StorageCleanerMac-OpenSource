#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D125: the connection page and the VPN page follow iStat Menus 7.30's
/// interface submenu (`-[NetworkMenu updateInterfaceSubmenu]`): the
/// interface, media options, Wi-Fi, addresses, IPv4 and IPv6 sections, each
/// only with rows, then the button item. Renders the production pages
/// offscreen with the demo fixtures; the copy action, the refresh and the
/// VPN action fail the test if anything calls them, and the Wi-Fi switch is
/// never toggled. No pasteboard, panel, window, network change or user data.
@MainActor
final class MiniWindowIStatInterfaceLayoutTests: XCTestCase {
    func testTheInterfaceSubmenuHasIStatsGeometry() {
        typealias Geometry = GeekIStatInterfaceGeometry
        XCTAssertEqual([Geometry.rowsTop, Geometry.bottom, Geometry.labelOnlyHeight, Geometry.addressRowHeight],
                       [22, 5, 25, 15])
        XCTAssertEqual([Geometry.buttonHeight, Geometry.buttonLabelInset, Geometry.buttonLabelTop], [31, 10, 7])
        XCTAssertEqual([Geometry.destructiveInset, Geometry.destructiveCornerRadius], [2, 6])
        // A text section is 27 + 17n, a label alone 25; the addresses 27 + 15n.
        XCTAssertEqual((0...3).map(Geometry.textSectionHeight(rows:)), [25, 44, 61, 78])
        XCTAssertEqual(Geometry.textSectionHeight(rows: 8), 163)
        XCTAssertEqual((1...3).map(Geometry.addressSectionHeight(addresses:)), [42, 57, 72])
        // D137 (2026-10-19): both pages are their widest section + 20, from
        // 220 (`GeekIStatContentWidth`; were the fixed
        // `GeekNetworkTertiaryView.pageWidth` 255 and
        // `GeekHoverDetailMetrics.vpnWidth` 220).
        XCTAssertEqual(GeekIStatInterfaceModel().pageWidth(), 220)
        XCTAssertEqual(GeekIStatContentWidth.page(sections: [GeekIStatContentWidth.sectionMinimum]), 220)
        XCTAssertEqual(GeekPanelLayout.detailSpacing, 7)
    }

    /// iStat's formats: Mb/s below a gigabit, 1 and 10 Gb/s whole, other
    /// speeds with one decimal; the band names; the media options.
    func testTheFormatsFollowTheMenu() {
        typealias Model = GeekIStatInterfaceModel
        XCTAssertEqual([100, 999, 1_000, 2_500, 10_000, 25_000].map(Model.linkSpeedText),
                       ["100 Mb/s", "999 Mb/s", "1 Gb/s", "2.5 Gb/s", "10 Gb/s", "25.0 Gb/s"])
        // D134: a zero speed is iStat's "%li Mb/s" row (was nil, no row).
        XCTAssertEqual(Model.linkSpeedText(0), "0 Mb/s")
        XCTAssertEqual([2, 5, 6, 3].map(Model.bandText), ["2.4GHz", "5GHz", "6GHz", nil])
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        // D134: the active media's option names (was a duplex text matched by
        // substrings: `mediaOptions(duplex: "full-duplex, flow-control")`,
        // `(duplex: "half-duplex")`, `(duplex: nil)`).
        XCTAssertEqual(Model.mediaOptions(["full-duplex", "flow-control"]), ["全双工", "流控制"])
        XCTAssertEqual(Model.mediaOptions(["half-duplex"]), ["半双工"])
        XCTAssertEqual(Model.mediaOptions([]), [])
    }

    /// The demo Wi-Fi connection: every row iStat lists for it, in order and
    /// in its words, with the mode's band and the channel's width.
    func testTheConnectionModelListsTheMenusRows() {
        for (language, wiFi) in [
            (AppLanguage.zhHans, ["网络", "BSSID", "模式", "传输速率", "RSSI", "噪音", "SNR", "频段"]),
            (.english, ["Network", "BSSID", "Mode", "Transmit Rate", "RSSI", "Noise", "SNR", "Channel"]),
        ] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let model = GeekIStatInterfaceModel(connection: Self.demoConnection)
            XCTAssertEqual(model.bsdName, "en0")
            XCTAssertEqual(model.hardwareAddress, "02:00:00:00:00:01")
            XCTAssertNil(model.linkSpeed, "a Wi-Fi link has no wired speed")
            XCTAssertEqual(model.mediaOptions, [])
            XCTAssertEqual(model.wiFiRows?.map(\.title), wiFi, "\(language)")
            XCTAssertEqual(model.wiFiRows?.map(\.value), [
                "Studio Wi-Fi", "02:00:00:00:00:02", "802.11ax (5GHz)", "1200 Mbps",
                "-48 dBm", "-92 dBm", "44 dB", "149 (80 Mhz)",
            ])
            XCTAssertEqual(model.addresses, ["192.0.2.35", "2001:db8::35"])
            XCTAssertEqual(model.ipv4Rows.map(\.value), ["255.255.255.0", "192.0.2.1", "192.0.2.53"])
            XCTAssertEqual(model.ipv4Rows.map(\.title), language == .zhHans
                ? ["子网掩码", "路由器", "DNS"] : ["Subnet Mask", "Router", "DNS"])
            XCTAssertEqual(model.ipv6Rows.map(\.value), ["2001:db8::1", "2001:db8::53"])
            XCTAssertEqual(model.sectionHeights, [61, 163, 57, 78, 61])
            // D137 (2026-10-19): as wide as its widest section + 20, 228 in
            // Chinese and 252 in English (was 255 × 464 in both).
            XCTAssertEqual(GeekNetworkTertiaryView.preferredSize(for: Self.demoConnection),
                           CGSize(width: language == .zhHans ? 228 : 252, height: 464), "\(language)")
        }
    }

    /// Off and unassociated, the Wi-Fi section is its label and switch; a
    /// section without rows is gone, the interface section stays.
    func testWiFiOffKeepsOnlyTheSectionsWithRows() {
        let model = GeekIStatInterfaceModel(connection: NetworkConnectionSnapshot.resolve(
            native: Self.wiFiOffSnapshot,
            topology: nil
        ))
        XCTAssertEqual(model.wiFiRows, [])
        XCTAssertEqual(model.addresses, [])
        XCTAssertEqual(model.sectionHeights, [61, 25])
        // Associated readings gate the mode, SNR and channel rows as in iStat.
        let unassociated = WiFiConnectionDetails(
            powerState: .onDisconnected, ssid: "Studio Wi-Fi", bssid: nil, phyMode: "802.11ax", bandGHz: 5,
            transmitRateMbps: 0, rssiDBm: 0, noiseDBm: nil, snrDB: nil, channelNumber: 149,
            channelWidthMHz: 80, countryCode: nil
        )
        XCTAssertEqual(GeekIStatInterfaceModel.wiFiRows(unassociated).map(\.value), ["Studio Wi-Fi"])
    }

    /// A VPN: its BSD name, its addresses, and its router and every scoped
    /// DNS server in the section of their family (was three DNS rows and
    /// "N more").
    func testTheTunnelModelListsEveryDNSServer() throws {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let tunnel = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNPPP))
        let model = GeekIStatInterfaceModel(tunnel: tunnel)
        XCTAssertEqual(model.bsdName, "ppp0")
        XCTAssertNil(model.hardwareAddress)
        XCTAssertNil(model.wiFiRows)
        // D140 (2026-10-19): the tunnel's addresses are point-to-point, so
        // iStat lists none and the section is gone (were "10.8.0.2" and
        // "fd00:8::2", sections [44, 57, 78]).
        XCTAssertEqual(model.addresses, [])
        XCTAssertEqual(model.ipv4Rows.map(\.title), ["路由器", "DNS", "DNS"])
        XCTAssertEqual(model.ipv4Rows.map(\.value), ["198.51.100.24", "10.8.0.1", "1.1.1.1"])
        XCTAssertEqual(model.ipv6Rows, [])
        XCTAssertEqual(model.sectionHeights, [44, 78])

        let many = Self.tunnel(tunnel, dns: ["10.8.0.1", "10.8.0.2", "10.8.0.3", "10.8.0.4", "fd00:8::53"])
        let manyModel = GeekIStatInterfaceModel(tunnel: many)
        XCTAssertEqual(manyModel.ipv4Rows.count, 5, "the router and four DNS rows")
        XCTAssertEqual(manyModel.ipv6Rows.map(\.value), ["fd00:8::53"])

        // D137 (2026-10-19): 220 is now the sections' 200 + 20 (was the fixed
        // `GeekHoverDetailMetrics.vpnWidth`). D140: without the address
        // section (were 247 and 209).
        XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: tunnel), CGSize(width: 220, height: 183))
        let readOnly = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNReadOnly))
        XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: readOnly), CGSize(width: 220, height: 145))
        // A snapshot without the list keeps the tunnel's addresses.
        XCTAssertEqual(GeekIStatInterfaceModel(tunnel: Self.tunnel(tunnel, dns: [])).addresses,
                       ["10.8.0.2", "fd00:8::2"])
    }

    /// The rendered pages are as tall as their sizes in both languages: the
    /// connection page 464, a VPN with its button 183, a read-only one 145.
    /// D137 (2026-10-19): each is rendered at its own width (were 255 and 220).
    /// D140: the VPNs list no address (were 247 and 209).
    func testRenderedPagesMatchTheirSizes() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let connection = Self.connectionPage(Self.demoSnapshot)
            let width = GeekNetworkTertiaryView.preferredSize(for: Self.demoConnection).width
            let bitmap = try Self.render(connection, width: width, mode: .black)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, width, "\(language)")
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 464, accuracy: 0.5, "\(language) connection")
            let offConnection = NetworkConnectionSnapshot.resolve(native: Self.wiFiOffSnapshot, topology: nil)
            let off = try Self.render(Self.connectionPage(Self.wiFiOffSnapshot),
                                      width: GeekNetworkTertiaryView.preferredSize(for: offConnection).width,
                                      mode: .black)
            XCTAssertEqual(CGFloat(off.pixelsHigh) / 2, 16 + 61 + 7 + 25, accuracy: 0.5, "\(language) Wi-Fi off")
            if language == .zhHans {
                try Self.export(name: "l3-network-connection") { mode in
                    try Self.render(Self.connectionPage(Self.demoSnapshot), width: width, mode: mode)
                }
            }
            let scenarios: [(MiniWindowDemoData.MenuBarSnapshotScenario, CGFloat)] = [
                (.networkVPNPPP, 183), (.networkVPNThirdParty, 183), (.networkVPNSystem, 183),
                (.networkVPNReadOnly, 145),
            ]
            for (scenario, height) in scenarios {
                let tunnel = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: scenario))
                let vpnWidth = GeekVPNHoverDetail.preferredSize(for: tunnel).width
                let page = try Self.render(Self.vpnPage(tunnel), width: vpnWidth, mode: .black)
                XCTAssertEqual(CGFloat(page.pixelsWide) / 2, vpnWidth, "\(language) \(scenario)")
                XCTAssertEqual(CGFloat(page.pixelsHigh) / 2, height, accuracy: 0.5, "\(language) \(scenario)")
                XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: tunnel).height, height, "\(scenario)")
                if language == .zhHans {
                    try Self.export(name: "l3-\(scenario.rawValue)") { mode in
                        try Self.render(Self.vpnPage(tunnel), width: vpnWidth, mode: mode)
                    }
                }
            }
        }
    }

    /// The disconnect request is iStat's red button item: the gradient from
    /// (1, 0.242, 0.246) at the top to (1, 0.082, 0.086) at the bottom inside
    /// its 2 pt inset; opening System Settings is a standard item on the card.
    func testTheDisconnectButtonIsTheMenusRedItem() throws {
        // D140 (2026-10-19): no address section (was 8 + 44 + 7 + 57 + 7 +
        // 78 + 7).
        let buttonTop: CGFloat = 8 + 44 + 7 + 78 + 7
        let x: CGFloat = 8 + 14
        func color(_ bitmap: NSBitmapImageRep, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
        }
        for mode in [MiniWindowVisualMode.black, .graphite] {
            let ppp = try Self.render(Self.vpnPage(try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNPPP))),
                                      width: 220, mode: mode)
            let top = try color(ppp, buttonTop + 5)
            let bottom = try color(ppp, buttonTop + GeekIStatInterfaceGeometry.buttonHeight - 5)
            for sample in [top, bottom] {
                XCTAssertGreaterThan(sample.redComponent, 0.9, "\(mode) \(sample)")
                XCTAssertLessThan(sample.greenComponent, 0.35, "\(mode) \(sample)")
            }
            XCTAssertGreaterThan(top.greenComponent - bottom.greenComponent, 0.05, "lighter at the top: \(mode)")

            let system = try Self.render(
                Self.vpnPage(try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNSystem))),
                width: 220, mode: mode
            )
            let standard = try color(system, buttonTop + 15)
            XCTAssertLessThan(standard.redComponent - standard.greenComponent, 0.15, "standard item: \(mode)")
        }
    }

    /// The MAC address keeps its first four bytes masked until it is shown;
    /// the rows copy through the injected action; the titles keep iStat's
    /// case; the page keeps its accessibility contract.
    func testTheSectionsKeepTheirContracts() throws {
        XCTAssertEqual(GeekIStatHardwareAddressRow.displayed("02:00:00:00:00:01", isRevealed: false),
                       "••:••:••:••:00:01")
        XCTAssertEqual(GeekIStatHardwareAddressRow.displayed("02:00:00:00:00:01", isRevealed: true),
                       "02:00:00:00:00:01")
        XCTAssertEqual(GeekIStatHardwareAddressRow.displayed("unknown", isRevealed: false), "••:••:••:••:••:••")

        let sections = try Self.source("Views/MenuBarAdvanced/GeekIStatInterfaceSections.swift")
        let row = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatSelectableRow<Content: View>: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(row.contains("copyAction.perform(value)"))
        XCTAssertTrue(row.contains(".accessibilityHint("))
        XCTAssertTrue(sections.contains("pasteboard.setString(value, forType: .string)"))
        XCTAssertTrue(sections.contains("MenuBarStatusController.shared.dismissPanel()"))
        // Only the addresses' label is upper case; the others are as given.
        // D140 (2026-10-19): the addresses are iStat's IP section (was
        // `GeekIStatMajorLabelRow(title: GeekIStatInterfaceModel.addressesTitle)`).
        XCTAssertTrue(sections.contains(
            "GeekIStatIPSection(title: GeekIStatInterfaceModel.addressesTitle, addresses: model.addresses)"
        ))
        let ipSection = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatIPSection: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(ipSection.contains("GeekIStatMajorLabelRow(\n                title: title,"))
        XCTAssertFalse(ipSection.contains("isUppercased"))
        XCTAssertEqual(sections.components(separatedBy: "isUppercased: false").count - 1, 4)

        let network = try Self.source("Views/MenuBarAdvanced/GeekNetworkView.swift")
        let vpn = try XCTUnwrap(network.components(separatedBy: "struct GeekVPNHoverDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(vpn.contains("isConfirmingDisconnect = true"), "a disconnect still asks first")
        XCTAssertTrue(vpn.contains(".help(managementDescription)"))
        XCTAssertTrue(vpn.contains("GeekIStatNoteCard(text: actionMessage)"))
        XCTAssertFalse((network + sections).contains("DHCP续租"), "iStat's DHCP renew is not copied")
        XCTAssertTrue(network.contains(".toggleStyle(GeekIStatSwitchToggleStyle())"))
        XCTAssertTrue(network.contains("L10n.text(\"关闭 Wi-Fi？\", \"Turn Off Wi-Fi?\")"))
    }

    // MARK: - Helpers

    private static let demoSnapshot = MiniWindowDemoData.networkInterfaceSnapshot

    private static var demoConnection: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(native: demoSnapshot, topology: nil)
    }

    /// The demo interface with Wi-Fi off: no network, readings or addresses.
    private static let wiFiOffSnapshot = NativeNetworkInterfaceSnapshot(
        generatedAt: MiniWindowDemoData.referenceDate,
        interfaceName: "en0",
        wiFiInterfaceName: "en0",
        isWiFiPoweredOn: false,
        hardwareAddress: "02:00:00:00:00:01",
        ssid: nil,
        bssid: nil,
        countryCode: nil,
        wiFiPHYMode: nil,
        transmitRateMbps: nil,
        rssiDBm: nil,
        noiseDBm: nil,
        channelNumber: nil,
        channelBandGHz: nil,
        channelWidthMHz: nil,
        ipv4Addresses: [],
        ipv6Addresses: [],
        ipv4SubnetMask: nil,
        ipv4Router: nil,
        ipv6Router: nil,
        dnsServers: [],
        interfaceMTU: nil,
        linkSpeedMbps: nil
    )

    private static func tunnel(_ tunnel: VPNTunnelSnapshot, dns: [String]) -> VPNTunnelSnapshot {
        VPNTunnelSnapshot(
            stableID: tunnel.stableID, serviceID: tunnel.serviceID, displayName: tunnel.displayName,
            providerName: tunnel.providerName, providerBundleIdentifier: tunnel.providerBundleIdentifier,
            providerApplicationURL: tunnel.providerApplicationURL, protocolKind: tunnel.protocolKind,
            bsdName: tunnel.bsdName, status: tunnel.status, tunnelIPv4: tunnel.tunnelIPv4,
            tunnelIPv6: tunnel.tunnelIPv6, scopedDNSServers: dns,
            gatewayOrRemoteAddress: tunnel.gatewayOrRemoteAddress, isDefaultRoute: tunnel.isDefaultRoute,
            isSplitTunnel: tunnel.isSplitTunnel
        )
    }

    private static func connectionPage(_ snapshot: NativeNetworkInterfaceSnapshot) -> GeekNetworkTertiaryView {
        GeekNetworkTertiaryView(snapshot: snapshot, topology: nil, refresh: {
            XCTFail("A render must never refresh")
        })
    }

    private static func vpnPage(_ tunnel: VPNTunnelSnapshot) -> GeekVPNHoverDetail {
        GeekVPNHoverDetail(
            tunnel: tunnel,
            refresh: { XCTFail("A render must never refresh") },
            capabilityResolver: MiniWindowDemoData.vpnCapabilityResolver,
            controlAction: { _ in
                XCTFail("A render must never request a VPN action")
                return .unavailable(.unsupported)
            }
        )
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/\(path)"), encoding: .utf8)
    }

    /// As a level-three page in its column: the content on the column's
    /// width less the page's 8 pt insets.
    private static func render<Content: View>(_ page: Content, width: CGFloat,
                                              mode: MiniWindowVisualMode) throws -> NSBitmapImageRep {
        let content = page
            .frame(width: width - 2 * GeekPanelLayout.contentPadding, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.miniWindowPageProvidesInset, true)
            .environment(\.geekIStatCopyAction, GeekIStatCopyAction { _ in
                XCTFail("A render must never copy")
            })
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Night is black, day is graphite (D44, D56).
    private static func export(name: String, render: (MiniWindowVisualMode) throws -> NSBitmapImageRep) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (mode, suffix) in [(MiniWindowVisualMode.black, "night"), (.graphite, "day")] {
            try XCTUnwrap(try render(mode).representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

#endif
