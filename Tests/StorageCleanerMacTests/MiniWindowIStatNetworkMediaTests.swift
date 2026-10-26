#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D134 (R8d): iStat Menus 7.30 reads a link's speed from the network
/// controller's `IOLinkSpeed` (`-[BBRStatisticsNetwork infoForService:]`: the
/// parent of the entry matching the BSD name, / 1 000 000) and its media from
/// the active dictionary of `SCNetworkInterfaceCopyMediaOptions`
/// (`updateMediaOptions:`). The interface submenu
/// (`-[NetworkMenu updateInterfaceSubmenu]`) shows both only while connected,
/// the speed not for Wi-Fi and a zero speed from a "…baseT" subtype, the
/// options with its labels for full duplex, half duplex and flow control and
/// any other option as the system names it. Fixtures only: no network
/// reading, window or user data.
@MainActor
final class MiniWindowIStatNetworkMediaTests: XCTestCase {
    typealias Model = GeekIStatInterfaceModel

    /// "%li Mb/s" below 1000 (0 included), "1 Gb/s" and "10 Gb/s" whole, any
    /// other speed "%.1f Gb/s" of the single-precision quotient.
    func testTheLinkSpeedFollowsTheMenusThresholds() {
        XCTAssertEqual([0, 10, 100, 999].map(Model.linkSpeedText), ["0 Mb/s", "10 Mb/s", "100 Mb/s", "999 Mb/s"])
        XCTAssertEqual([1_000, 10_000].map(Model.linkSpeedText), ["1 Gb/s", "10 Gb/s"])
        XCTAssertEqual([1_001, 2_500, 5_000, 9_999, 10_001, 25_000, 40_000].map(Model.linkSpeedText),
                       ["1.0 Gb/s", "2.5 Gb/s", "5.0 Gb/s", "10.0 Gb/s", "10.0 Gb/s", "25.0 Gb/s", "40.0 Gb/s"])
        // iStat divides as floats: 1050 / 1000 is just below 1.05 there.
        XCTAssertEqual(Model.linkSpeedText(1_050), "1.0 Gb/s")
    }

    /// A zero speed takes the number before "baseT" (`integerValue`); any
    /// other subtype keeps the zero, a speed ignores the subtype.
    func testAZeroSpeedTakesTheBaseTSubtype() {
        XCTAssertEqual(Model.displayedLinkSpeed(0, mediaSubType: "1000baseT"), 1_000)
        XCTAssertEqual(Model.displayedLinkSpeed(0, mediaSubType: "10GbaseT"), 10, "integerValue stops at the G")
        XCTAssertEqual(Model.displayedLinkSpeed(0, mediaSubType: "100baseTX"), 0, "only a subtype ending in baseT")
        XCTAssertEqual(Model.displayedLinkSpeed(0, mediaSubType: "autoselect"), 0)
        XCTAssertEqual(Model.displayedLinkSpeed(0, mediaSubType: nil), 0)
        XCTAssertEqual(Model.displayedLinkSpeed(2_500, mediaSubType: "1000baseT"), 2_500, "a speed is kept")
    }

    /// The options in the system's order with iStat's words
    /// (`BBRMenuKit.strings`: 全双工, 半双工, 流控制); others unchanged.
    func testTheMediaOptionsUseTheMenusLabels() {
        let options = ["full-duplex", "flow-control", "energy-efficient-ethernet", "half-duplex"]
        for (language, expected) in [
            (AppLanguage.zhHans, ["全双工", "流控制", "energy-efficient-ethernet", "半双工"]),
            (.english, ["Full Duplex", "Flow Control", "energy-efficient-ethernet", "Half Duplex"]),
        ] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(Model.mediaOptions(options), expected, "\(language)")
        }
        XCTAssertEqual(Model.mediaOptions([]), [])
    }

    /// The readings as iStat stores them: whole Mb/s of `IOLinkSpeed` (64-bit,
    /// so 10 Gb/s and more), the active media's subtype and options, and no
    /// all-zero MAC address.
    func testTheReadingsConvertAsIStatStoresThem() {
        typealias Service = NativeNetworkInterfaceService
        XCTAssertEqual(Service.megabits(fromLinkSpeed: 1_000_000_000), 1_000)
        XCTAssertEqual(Service.megabits(fromLinkSpeed: 2_500_000_000), 2_500)
        XCTAssertEqual(Service.megabits(fromLinkSpeed: 10_000_000_000), 10_000,
                       "beyond the 4.29 Gb/s of if_data.ifi_baudrate")
        XCTAssertEqual(Service.megabits(fromLinkSpeed: 999_999), 0)
        XCTAssertEqual(Service.megabits(fromLinkSpeed: .nan), 0)

        let media = Service.activeMedia(from: [
            "MediaSubType": "1000baseT", "MediaOptions": ["full-duplex", "flow-control"],
        ])
        XCTAssertEqual(media.subType, "1000baseT")
        XCTAssertEqual(media.options, ["full-duplex", "flow-control"])
        let malformed = Service.activeMedia(from: ["MediaSubType": 1, "MediaOptions": "full-duplex"])
        XCTAssertNil(malformed.subType)
        XCTAssertEqual(malformed.options, [])

        XCTAssertNil(Service.meaningfulHardwareAddress("00:00:00:00:00:00"))
        XCTAssertNil(Service.meaningfulHardwareAddress(nil))
        XCTAssertEqual(Service.meaningfulHardwareAddress("02:00:00:00:00:0c"), "02:00:00:00:00:0c")
    }

    /// A connected wired link: its speed and media options rows, the media
    /// section after the interface section; a zero speed from the subtype or
    /// "0 Mb/s"; no `IOLinkSpeed`, no row; no options, no section.
    func testAWiredConnectionShowsItsSpeedAndMedia() {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let connection = NetworkConnectionSnapshot.resolve(native: Self.wired(), topology: Self.topology(isUp: true))
        XCTAssertEqual(connection.connectionKind, .ethernet)
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(connection.mediaSubType, "2500Base-T")
        XCTAssertEqual(connection.mediaOptions, ["full-duplex", "flow-control"])
        let model = Model(connection: connection)
        XCTAssertEqual(model.hardwareAddress, "02:00:00:00:00:0C")
        XCTAssertEqual(model.linkSpeed, "2.5 Gb/s")
        XCTAssertEqual(model.mediaOptions, ["全双工", "流控制"])
        XCTAssertEqual(Array(model.sectionHeights.prefix(2)), [78, 61], "BSD, MAC and speed; two options")

        XCTAssertEqual(Self.model(Self.wired(linkSpeed: 0, subType: "1000baseT")).linkSpeed, "1 Gb/s")
        XCTAssertEqual(Self.model(Self.wired(linkSpeed: 0, subType: "autoselect")).linkSpeed, "0 Mb/s",
                       "iStat's row for a zero speed")
        XCTAssertNil(Self.model(Self.wired(linkSpeed: nil)).linkSpeed, "no IOLinkSpeed, no row")
        let noOptions = Self.model(Self.wired(options: []))
        XCTAssertEqual(noOptions.mediaOptions, [])
        XCTAssertEqual(Array(noOptions.sectionHeights.prefix(2)), [78, 42], "no media section")
    }

    /// Not connected: the readings stay in the snapshot, the page shows no
    /// speed and no media options (iStat's disconnected submenu has neither).
    func testADisconnectedLinkHasNoSpeedOrMedia() {
        let connection = NetworkConnectionSnapshot.resolve(
            native: Self.wired(addresses: []),
            topology: Self.topology(isUp: false)
        )
        XCTAssertEqual(connection.connectionKind, .ethernet)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(connection.ethernet?.linkSpeedMbps, 2_500)
        XCTAssertEqual(connection.mediaOptions, ["full-duplex", "flow-control"])
        let model = Model(connection: connection)
        XCTAssertNil(model.linkSpeed)
        XCTAssertEqual(model.mediaOptions, [])
    }

    /// The media is the connection's only when the native reading is its
    /// interface (as the MAC address); without a topology it is.
    func testAnotherInterfacesMediaIsNotTheConnections() {
        let connection = NetworkConnectionSnapshot.resolve(
            native: Self.wired(interfaceName: "en0"),
            topology: Self.topology(isUp: true)
        )
        XCTAssertEqual(connection.activeInterface?.bsdName, "en12")
        XCTAssertNil(connection.mediaSubType)
        XCTAssertEqual(connection.mediaOptions, [])
        XCTAssertNil(connection.ethernet?.linkSpeedMbps)
        let alone = NetworkConnectionSnapshot.resolve(native: Self.wired(), topology: nil)
        XCTAssertEqual(alone.mediaSubType, "2500Base-T")
        XCTAssertEqual(alone.mediaOptions, ["full-duplex", "flow-control"])
    }

    /// iStat lists the active media's options for any interface; Wi-Fi has
    /// no wired speed row.
    func testWiFiShowsItsMediaOptionsButNoSpeed() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        var native = MiniWindowDemoData.networkInterfaceSnapshot
        native.mediaOptions = ["full-duplex"]
        let model = Model(connection: .resolve(native: native, topology: nil))
        XCTAssertNil(model.linkSpeed)
        XCTAssertEqual(model.mediaOptions, ["Full Duplex"])
        XCTAssertEqual(Model(connection: .resolve(native: MiniWindowDemoData.networkInterfaceSnapshot, topology: nil))
            .mediaOptions, [], "the demo Wi-Fi has no options")
    }

    /// The reader uses iStat's sources: the controller's `IOLinkSpeed` and
    /// the active media; `if_data.ifi_baudrate` is gone.
    func testTheReaderUsesIStatsSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/NativeNetworkInterfaceService.swift"
            ),
            encoding: .utf8
        )
        let compact = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for fragment in [
            "IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)",
            "IORegistryEntryGetParentEntry(entry, kIOServicePlane, &controller)",
            "IORegistryEntryCreateCFProperty( controller, \"IOLinkSpeed\" as CFString,",
            "SCNetworkInterfaceCopyMediaOptions(interface, nil, &active, nil, false)",
            "linkSpeedMbps: interfaceName.flatMap(linkSpeedMbps(bsdName:))",
            "mediaSubType: media.subType",
            "mediaOptions: media.options",
        ] {
            XCTAssertTrue(compact.contains(fragment), fragment)
        }
        XCTAssertFalse(source.contains("interfaceData.ifi_baudrate"), "the 32-bit speed is not read")
    }

    // MARK: - Fixtures

    private static func model(_ native: NativeNetworkInterfaceSnapshot) -> Model {
        Model(connection: .resolve(native: native, topology: topology(isUp: true)))
    }

    /// A USB Ethernet adapter, en12, beside the Wi-Fi interface en0.
    private static func wired(
        interfaceName: String = "en12",
        linkSpeed: Int? = 2_500,
        subType: String? = "2500Base-T",
        options: [String] = ["full-duplex", "flow-control"],
        addresses: [String] = ["192.0.2.35"]
    ) -> NativeNetworkInterfaceSnapshot {
        NativeNetworkInterfaceSnapshot(
            generatedAt: MiniWindowDemoData.referenceDate,
            interfaceName: interfaceName,
            wiFiInterfaceName: "en0",
            isWiFiPoweredOn: true,
            hardwareAddress: "02:00:00:00:00:0c",
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
            ipv4Addresses: addresses,
            ipv6Addresses: [],
            ipv4SubnetMask: addresses.isEmpty ? nil : "255.255.255.0",
            ipv4Router: addresses.isEmpty ? nil : "192.0.2.1",
            ipv6Router: nil,
            dnsServers: ["192.0.2.53"],
            interfaceMTU: 1_500,
            linkSpeedMbps: linkSpeed,
            mediaSubType: subType,
            mediaOptions: options
        )
    }

    private static func topology(isUp: Bool) -> NetworkTopologySnapshot {
        NetworkTopologyResolver.resolve(
            NetworkTopologyResolverInput(
                timestamp: MiniWindowDemoData.referenceDate,
                primaryServiceID: "usb-lan-service",
                primaryInterfaceName: "en12",
                wiFiInterfaceName: "en0",
                wiFiSSID: nil,
                globalDNSServers: ["192.0.2.53"],
                services: [
                    .init(
                        serviceID: "usb-lan-service",
                        displayName: "USB Ethernet",
                        interfaceType: "Ethernet",
                        bsdName: "en12",
                        runtimeBSDName: "en12",
                        gatewayOrRemoteAddress: "192.0.2.1"
                    ),
                ],
                interfaces: [
                    .init(bsdName: "en0", isUp: true),
                    .init(bsdName: "en12", isUp: isUp, ipv4Addresses: isUp ? ["192.0.2.35"] : []),
                ]
            )
        )
    }
}
#endif
