#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D137: the content-sized level-three pages take iStat Menus 7.30's
/// widths. A text section is its widest row + 16, from 200 (150 in the
/// uptime menu) to 350; a label-and-value row is ceil(label) + ceil(value) +
/// 30 and a row of one text its text; a button is its label + 20, from 200
/// to 350; a content-sized submenu is its widest section, truncated, + 20
/// (`-[BBRMenuTextSection intrinsicContentSize]`, `-[BBRButtonMenuItem
/// intrinsicContentSize]`, `setWidth:` in `-[NetworkMenu
/// updateInterfaceSubmenu]`, `-[BatteryMenu updateBatterySubmenu]` and
/// `-[CPUMenu updateUptimeSubmenu]`). Measures and renders the production
/// pages offscreen with the demo fixtures; the copy action, the refresh and
/// the VPN action fail the test if anything calls them. No pasteboard,
/// window, network change or user data.
@MainActor
final class MiniWindowIStatContentWidthTests: XCTestCase {
    typealias Width = GeekIStatContentWidth

    func testTheWidthsFollowIStatsRules() {
        XCTAssertEqual([Width.sectionMinimum, Width.sectionMaximum], [200, 350], "initWithFrame: 0xc8, 0x15e")
        XCTAssertEqual([Width.rowPadding, Width.buttonPadding, Width.pagePadding], [30, 20, 20])
        XCTAssertEqual(GeekIStatTextSectionGeometry.widthPadding, 16)
        XCTAssertEqual(GeekIStatTextSectionGeometry.minimumWidth, 150, "setMinimumWidth: 150")
        // A section: its widest row + 16, from its minimum to 350.
        XCTAssertEqual(Width.section(rows: []), 200)
        XCTAssertEqual(Width.section(rows: [120, 184]), 200)
        XCTAssertEqual(Width.section(rows: [185, 40]), 201)
        XCTAssertEqual(Width.section(rows: [333]), 349)
        XCTAssertEqual(Width.section(rows: [400]), 350)
        XCTAssertEqual(Width.section(rows: [100], minimum: 150), 150)
        XCTAssertEqual(Width.section(rows: [150], minimum: 150), 166)
        // The submenu: its widest section, truncated, + 20.
        XCTAssertEqual(Width.page(sections: [200]), 220)
        XCTAssertEqual(Width.page(sections: [233.9, 201]), 253)
        XCTAssertEqual(Width.page(sections: [350]), 370)
        // A button: its label + 20, from 200 to 350.
        XCTAssertEqual(Width.button(title: ""), 200)
        XCTAssertEqual(Width.button(title: String(repeating: "W", count: 40)), 350)
        let digits = String(repeating: "8", count: 26)
        XCTAssertGreaterThan(Width.text(digits) + 20, 200)
        XCTAssertLessThan(Width.text(digits) + 20, 350)
        XCTAssertEqual(Width.button(title: digits), Width.text(digits) + 20)
    }

    /// Text is measured in the rows' 12 pt regular font with monospaced
    /// digits (`geekIStatLabelText`, `geekIStatValueText`), rounded up.
    func testTextIsMeasuredInTheRowsFont() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for text in ["802.11ax (5GHz)", "MAC Address", "子网掩码", "1200 Mbps", "Not supported on this Mac"] {
            XCTAssertEqual(Width.text(text), ceil((text as NSString).size(withAttributes: [.font: font]).width), text)
        }
        XCTAssertEqual(Width.text(""), 0)
        XCTAssertEqual(Width.text("1111"), Width.text("8888"), "monospaced digits")
        XCTAssertEqual(Width.row(title: "DNS", value: "192.0.2.53"), Width.text("DNS") + Width.text("192.0.2.53") + 30)
    }

    /// The demo Wi-Fi connection: the interface section is the widest (its
    /// MAC address row), 228 in Chinese and 252 in English (was 255 in
    /// both). The addresses never widen the page; any other row does.
    func testTheConnectionPageIsItsWidestSectionPlusTwenty() throws {
        for (language, expected) in [(AppLanguage.zhHans, CGFloat(228)), (.english, 252)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            var model = GeekIStatInterfaceModel(connection: Self.demoConnection)
            let wiFiRows = try XCTUnwrap(model.wiFiRows)
            let sections = [
                Self.section([(GeekIStatInterfaceModel.bsdNameTitle, "en0"),
                              (GeekIStatInterfaceModel.hardwareAddressTitle, "02:00:00:00:00:01")]),
                Self.section(wiFiRows.map { ($0.title, $0.value) }),
                Self.section(model.ipv4Rows.map { ($0.title, $0.value) }),
                Self.section(model.ipv6Rows.map { ($0.title, $0.value) }),
            ]
            XCTAssertEqual(sections.max(), sections.first, "\(language): the MAC address row is the widest")
            XCTAssertEqual(model.pageWidth(), (sections.max() ?? 0).rounded(.down) + 20, "\(language)")
            XCTAssertEqual(model.pageWidth(), expected, "\(language)")
            XCTAssertEqual(GeekNetworkTertiaryView.preferredSize(for: Self.demoConnection),
                           CGSize(width: expected, height: 464), "\(language)")

            let long = "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
            model.addresses.append(long)
            XCTAssertEqual(model.pageWidth(), expected, "\(language): the addresses take the page's width")
            model.ipv6Rows.append(.init(title: "DNS", value: long))
            XCTAssertEqual(model.pageWidth(), Self.section([("DNS", long)]).rounded(.down) + 20, "\(language)")
            XCTAssertGreaterThan(model.pageWidth(), expected)
        }
    }

    /// A long row widens the page in every measured section: the interface's
    /// BSD name and link speed, Wi-Fi, IPv4 and IPv6; an address never does.
    func testEveryMeasuredSectionWidensThePage() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        typealias Model = GeekIStatInterfaceModel
        let long = "fd00:0db8:85a3:0000:0000:8a2e:0370:7334"
        func page(_ title: String) -> CGFloat { Self.section([(title, long)]).rounded(.down) + 20 }
        let cases: [(String, Model, CGFloat)] = [
            ("BSD name", Model(bsdName: long), page(Model.bsdNameTitle)),
            ("link speed", Model(linkSpeed: long), page(Model.linkSpeedTitle)),
            ("Wi-Fi", Model(wiFiRows: [.init(title: "Network", value: long)]), page("Network")),
            ("IPv4", Model(ipv4Rows: [.init(title: "DNS", value: long)]), page("DNS")),
            ("IPv6", Model(ipv6Rows: [.init(title: "DNS", value: long)]), page("DNS")),
        ]
        for (name, model, width) in cases {
            XCTAssertGreaterThan(width, 220, name)
            XCTAssertEqual(model.pageWidth(), width, name)
        }
        XCTAssertEqual(Model(addresses: [long]).pageWidth(), 220, "the addresses take the page's width")
    }

    /// The MAC address counts the wider of its masked and full forms; media
    /// options are rows of one label; an interface section without rows is
    /// the 200 pt minimum.
    func testTheInterfaceSectionCountsWhatItCanShow() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let title = GeekIStatInterfaceModel.hardwareAddressTitle
        for address in ["AA:BB:CC:DD:EE:FF", "1:2:3:4:5:6"] {
            let masked = GeekIStatHardwareAddressRow.displayed(address, isRevealed: false)
            let widest = max(Self.section([(title, address)]), Self.section([(title, masked)]))
            XCTAssertEqual(GeekIStatInterfaceModel(hardwareAddress: address).pageWidth(),
                           widest.rounded(.down) + 20, address)
        }
        XCTAssertGreaterThan(Width.text("AA:BB:CC:DD:EE:FF"), Width.text("••:••:••:••:EE:FF"), "the full form")
        XCTAssertGreaterThan(Width.text("••:••:••:••:5:6"), Width.text("1:2:3:4:5:6"), "the masked form")

        let option = "energy-efficient-ethernet, hardware-loopback"
        XCTAssertGreaterThan(Width.text(option) + 16, 200)
        XCTAssertEqual(GeekIStatInterfaceModel(mediaOptions: [option, "Full Duplex"]).pageWidth(),
                       min(350, Width.text(option) + 16).rounded(.down) + 20, "a label alone: no + 30")
        XCTAssertEqual(GeekIStatInterfaceModel().pageWidth(), 220)
    }

    /// Every demo VPN is the sections' 200 + 20 with or without its button;
    /// each action title is a 200 pt button. A long DNS server widens the
    /// page, its addresses do not.
    func testTheVPNPageCountsItsSectionsAndButton() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for scenario in [MiniWindowDemoData.MenuBarSnapshotScenario.networkVPNPPP, .networkVPNThirdParty,
                             .networkVPNSystem, .networkVPNReadOnly] {
                let tunnel = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: scenario))
                XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: tunnel).width, 220, "\(language) \(scenario)")
            }
            XCTAssertEqual(GeekVPNHoverDetail.actionTitles,
                           [L10n.text("断开连接", "Disconnect"), L10n.text("打开 VPN 应用", "Open VPN App"),
                            L10n.text("打开系统设置", "Open System Settings")])
            XCTAssertEqual(GeekVPNHoverDetail.actionTitles.map(Width.button), [200, 200, 200], "\(language)")
            let ppp = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNPPP))
            let long = "fd00:0db8:85a3:0000:0000:8a2e:0370:7334"
            XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: Self.tunnel(ppp, ipv6: [long], dns: [])).width,
                           220, "\(language): the addresses take the page's width")
            XCTAssertEqual(GeekVPNHoverDetail.preferredSize(for: Self.tunnel(ppp, ipv6: [], dns: [long])).width,
                           Self.section([("DNS", long)]).rounded(.down) + 20, "\(language)")
        }
        let network = try Self.source("Views/MenuBarAdvanced/GeekNetworkView.swift")
        // D140 (2026-10-19): the width first, then the sections at it (was
        // `width: model.pageWidth(buttonTitles: reservesButton ? actionTitles
        // : [])` in the size).
        XCTAssertTrue(network.contains("let width = model.pageWidth(buttonTitles: reservesButton ? actionTitles : [])"))
        XCTAssertTrue(network.contains("GeekVPNManagementAction(title: disconnectTitle, isDestructive: true)"))
    }

    /// The uptime page is its section + 20, the section its widest title (in
    /// upper case) or value + 16 from 150: 170 before a reading and for the
    /// demo (was 220).
    func testTheUptimePageIsItsSectionPlusTwentyFromOneFifty() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let empty = GeekProcessorUptimeHoverDetail(poweredOnAt: "—", awake: "—", asleep: "—")
            XCTAssertEqual(empty.popoverSize, CGSize(width: 170, height: 130), "\(language)")
            XCTAssertEqual(Self.uptimeDetail().popoverSize, CGSize(width: 170, height: 130), "\(language) demo")
            let value = "2026年10月11日 星期日 上午 3:12:45 · 已运行 12 天"
            let long = GeekProcessorUptimeHoverDetail(poweredOnAt: value, awake: "12 天 23 小时", asleep: "1 天 2 小时")
            XCTAssertGreaterThan(Width.text(value) + 16, 150)
            XCTAssertEqual(long.popoverSize.width, min(350, Width.text(value) + 16).rounded(.down) + 20, "\(language)")
        }
    }

    /// The battery page is its widest section + 20: the demo's rows fit the
    /// 200 pt minimum (220, as before); a long condition widens it.
    func testTheBatteryPageIsItsWidestSectionPlusTwenty() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let demo = Self.batteryDetail(condition: L10n.text("正常", "Normal"))
            XCTAssertEqual(demo.popoverSize,
                           GeekSensorPowerHoverDetailMetrics.batterySize(sectionRowCounts: demo.sectionRowCounts),
                           "\(language): 220 wide")
            let condition = L10n.text("建议维修，请联系 Apple 授权服务提供商", "Service Recommended Soon")
            let long = Self.batteryDetail(condition: condition)
            let health = Self.section([(L10n.text("状况", "Condition"), condition),
                                       (L10n.text("循环次数", "Cycles"), "512")])
            XCTAssertGreaterThan(health, 200, "\(language)")
            XCTAssertEqual(long.popoverSize.width, health.rounded(.down) + 20, "\(language)")
            XCTAssertEqual(long.popoverSize.height, demo.popoverSize.height, "\(language)")
        }
    }

    /// The pages' callers pass the content sizes: the processor and power
    /// pages, and the debug scenarios that render them.
    func testTheCallersPassTheContentSizes() throws {
        let processor = try Self.source("Views/MenuBarAdvanced/GeekProcessorView.swift")
        let power = try Self.source("Views/MenuBarAdvanced/GeekPowerView.swift")
        let status = try Self.source("Views/MenuBarAdvancedStatusView.swift")
        let uptimeTarget = try XCTUnwrap(processor
            .components(separatedBy: "private var geekProcessorUptimeHoverTarget: some View {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(uptimeTarget.contains("popoverSize: detail.popoverSize"))
        XCTAssertTrue(power.contains("popoverSize: geekBatteryElectricalDetail.popoverSize"))
        for scenario in ["case .cpuUptimeInspector:", "case .powerBatteryDetail:"] {
            let body = try XCTUnwrap(status.components(separatedBy: scenario).dropFirst().first?
                .components(separatedBy: "        case .").first, scenario)
            XCTAssertTrue(body.contains("preferredSize = detail.popoverSize"), scenario)
        }
        XCTAssertFalse((processor + power + status).contains("GeekHoverDetailMetrics.uptimeSize"))
    }

    /// Rendered at their sizes, the pages are as wide as the sizes say in
    /// both languages; outside a level-three column the connection page
    /// takes its own width (the palette path).
    func testRenderedPagesTakeTheirContentWidths() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let width = GeekNetworkTertiaryView.preferredSize(for: Self.demoConnection).width
            let column = try Self.render(Self.connectionPage, width: width, mode: .black)
            XCTAssertEqual(CGFloat(column.pixelsWide) / 2, width, "\(language)")
            XCTAssertEqual(CGFloat(column.pixelsHigh) / 2, 464, accuracy: 0.5, "\(language)")
            let standalone = ImageRenderer(content: Self.connectionPage
                .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate))
            standalone.scale = 2
            XCTAssertEqual(CGFloat(try XCTUnwrap(standalone.cgImage).width) / 2, width, "\(language) standalone")
            if language == .english {
                try Self.export(name: "l3-network-connection-en") { mode in
                    try Self.render(Self.connectionPage, width: width, mode: mode)
                }
                let uptime = Self.uptimeDetail()
                try Self.export(name: "l3-uptime-en") { mode in
                    try Self.render(uptime, width: uptime.popoverSize.width, mode: mode)
                }
                let battery = Self.batteryDetail(condition: "Service Recommended Soon")
                try Self.export(name: "l3-battery-electrical-long-en") { mode in
                    try Self.render(battery, width: battery.popoverSize.width, mode: mode)
                }
            }
        }
    }

    // MARK: - Helpers

    /// A text section of label-and-value rows, measured the way iStat does.
    private static func section(_ rows: [(String, String)]) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func measure(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let widest = rows.map { measure($0.0) + measure($0.1) + 30 }.max() ?? 0
        return min(350, max(200, widest + 16))
    }

    private static var demoConnection: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(native: MiniWindowDemoData.networkInterfaceSnapshot, topology: nil)
    }

    private static var connectionPage: GeekNetworkTertiaryView {
        GeekNetworkTertiaryView(snapshot: MiniWindowDemoData.networkInterfaceSnapshot, topology: nil, refresh: {
            XCTFail("A render must never refresh")
        })
    }

    private static func tunnel(_ tunnel: VPNTunnelSnapshot, ipv6: [String], dns: [String]) -> VPNTunnelSnapshot {
        VPNTunnelSnapshot(
            stableID: tunnel.stableID, serviceID: tunnel.serviceID, displayName: tunnel.displayName,
            providerName: tunnel.providerName, providerBundleIdentifier: tunnel.providerBundleIdentifier,
            providerApplicationURL: tunnel.providerApplicationURL, protocolKind: tunnel.protocolKind,
            bsdName: tunnel.bsdName, status: tunnel.status, tunnelIPv4: tunnel.tunnelIPv4,
            tunnelIPv6: tunnel.tunnelIPv6 + ipv6, scopedDNSServers: tunnel.scopedDNSServers + dns,
            gatewayOrRemoteAddress: tunnel.gatewayOrRemoteAddress, isDefaultRoute: tunnel.isDefaultRoute,
            isSplitTunnel: tunnel.isSplitTunnel
        )
    }

    /// As the processor page passes the demo's readings.
    private static func uptimeDetail() -> GeekProcessorUptimeHoverDetail {
        let sinceBoot: TimeInterval = 734_400
        let bootAt = MiniWindowDemoData.referenceDate.addingTimeInterval(-sinceBoot)
        return GeekProcessorUptimeHoverDetail(
            poweredOnAt: PanelTimestampFormat.monthDayAndTime(bootAt),
            awake: GeekUptimeFormat.duration(MiniWindowDemoData.systemAwakeSeconds),
            asleep: GeekUptimeFormat.duration(GeekUptimeFormat.asleepSeconds(
                bootAt: bootAt, sinceBootSeconds: sinceBoot, awakeSeconds: MiniWindowDemoData.systemAwakeSeconds
            ))
        )
    }

    /// As the power page passes the demo's readings, with `condition`.
    private static func batteryDetail(condition: String) -> GeekBatteryElectricalHoverDetail {
        let battery = MiniWindowDemoData.batterySnapshot
        return GeekBatteryElectricalHoverDetail(
            electrical: MiniWindowDemoData.batteryElectricalSnapshot,
            cycleCount: 512,
            condition: condition,
            chargePercent: battery.chargePercent,
            healthPercent: MiniWindowDemoData.healthSummary.batteryCapacityPercent,
            statusText: L10n.text("使用电池", "On Battery"),
            isCharging: battery.isCharging,
            chargeTargetPercent: 80,
            remainingTimeMinutes: battery.remainingTimeMinutes
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
