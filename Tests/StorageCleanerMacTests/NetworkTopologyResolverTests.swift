import XCTest
@testable import StorageCleanerMac

final class NetworkTopologyResolverTests: XCTestCase {
    func testNativeAdapterBuildsReadOnlyTopologySnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_000_123)
        let snapshot = NativeNetworkInterfaceService.topologySnapshot(now: now)

        XCTAssertEqual(snapshot.timestamp, now)
        XCTAssertTrue(
            Set(snapshot.physicalAddresses.map(\.id))
                .intersection(snapshot.tunnelAddresses.map(\.id))
                .isEmpty
        )
    }

    func testNoVPNKeepsPhysicalTransportAndLocalAddressSeparate() {
        let snapshot = resolve(
            primaryServiceID: "wifi-service",
            primaryInterfaceName: "en0",
            wiFiInterfaceName: "en0",
            wiFiSSID: "Home WiFi",
            services: [
                physicalService(serviceID: "wifi-service", name: "Home Wi-Fi", bsdName: "en0")
            ],
            interfaces: [
                .init(bsdName: "en0", isUp: true, ipv4Addresses: ["192.168.1.197"])
            ]
        )

        XCTAssertNil(snapshot.activeVPNTunnel)
        XCTAssertEqual(snapshot.physicalTransport?.displayName, "Home Wi-Fi")
        XCTAssertEqual(snapshot.physicalTransport?.kind, .wiFi)
        XCTAssertEqual(snapshot.physicalTransport?.ssid, "Home WiFi")
        XCTAssertEqual(snapshot.physicalAddresses.map(\.address), ["192.168.1.197"])
        XCTAssertEqual(snapshot.physicalAddresses.first?.classification, .localNetwork)
        XCTAssertEqual(snapshot.trafficSnapshot.primaryInterfaceNames, ["en0"])
        XCTAssertTrue(snapshot.trafficSnapshot.detailOnlyTunnelInterfaceNames.isEmpty)
    }

    func testIKEv2UsesServiceIdentityAndKeepsTunnelAddressOutOfLocalAddresses() throws {
        let snapshot = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec0",
            wiFiInterfaceName: "en0",
            services: [
                physicalService(serviceID: "wifi-service", name: "Wi-Fi", bsdName: "en0"),
                .init(
                    serviceID: "surfshark-service",
                    displayName: "Surfshark",
                    interfaceType: "IPSec",
                    runtimeBSDName: "ipsec0",
                    connectionStatus: .connected,
                    protocolHint: .ikev2,
                    dnsServers: ["162.252.172.57", "149.154.159.92"]
                )
            ],
            interfaces: [
                .init(bsdName: "en0", isUp: true, ipv4Addresses: ["192.168.1.197"]),
                .init(
                    bsdName: "ipsec0",
                    isUp: true,
                    isPointToPoint: true,
                    ipv4Addresses: ["10.6.1.169"]
                )
            ]
        )

        let vpn = try XCTUnwrap(snapshot.activeVPNTunnel)
        XCTAssertEqual(vpn.stableID, "service:surfshark-service")
        XCTAssertEqual(vpn.displayName, "Surfshark · IKEv2")
        XCTAssertEqual(vpn.providerName, "Surfshark")
        XCTAssertEqual(vpn.bsdName, "ipsec0")
        XCTAssertEqual(vpn.tunnelIPv4, ["10.6.1.169"])
        XCTAssertEqual(vpn.scopedDNSServers, ["149.154.159.92", "162.252.172.57"])
        XCTAssertEqual(snapshot.tunnelAddresses.first?.classification, .tunnel)
        XCTAssertEqual(snapshot.physicalAddresses.map(\.address), ["192.168.1.197"])
        XCTAssertFalse(snapshot.physicalAddresses.contains { $0.address == "10.6.1.169" })
        XCTAssertEqual(snapshot.trafficSnapshot.detailOnlyTunnelInterfaceNames, ["ipsec0"])

        let connection = NetworkConnectionSnapshot.resolve(native: nil, topology: snapshot)
        XCTAssertEqual(connection.ipConfiguration.ipv4Addresses, ["192.168.1.197"])
        XCTAssertFalse(connection.ipConfiguration.ipv4Addresses.contains("10.6.1.169"))
    }

    func testReconnectChangingIPSecBSDNamePreservesVPNStableIdentity() throws {
        let first = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec0",
            services: [vpnService(runtimeBSDName: "ipsec0")],
            interfaces: [.init(bsdName: "ipsec0", isUp: true, ipv4Addresses: ["10.6.1.169"])]
        )
        let reconnected = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec1",
            services: [vpnService(runtimeBSDName: "ipsec1")],
            interfaces: [.init(bsdName: "ipsec1", isUp: true, ipv4Addresses: ["10.6.2.169"])]
        )

        XCTAssertEqual(
            try XCTUnwrap(first.activeVPNTunnel).stableID,
            try XCTUnwrap(reconnected.activeVPNTunnel).stableID
        )
        XCTAssertEqual(try XCTUnwrap(reconnected.activeVPNTunnel).bsdName, "ipsec1")
    }

    func testDisconnectedSavedVPNWithoutRuntimeTunnelIsNotActive() {
        let snapshot = resolve(
            services: [
                .init(
                    serviceID: "saved-surfshark-service",
                    displayName: "Surfshark",
                    interfaceType: "IPSec",
                    bsdName: "ipsec0",
                    connectionStatus: .disconnected,
                    protocolHint: .ikev2
                )
            ]
        )

        XCTAssertNil(snapshot.activeVPNTunnel)
        XCTAssertTrue(snapshot.additionalVPNTunnels.isEmpty)
        XCTAssertTrue(snapshot.trafficSnapshot.detailOnlyTunnelInterfaceNames.isEmpty)
    }

    @MainActor
    func testVPNStatusChangesNetworkSignatureAndPublicRefreshDecision() {
        let connecting = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec0",
            services: [
                .init(
                    serviceID: "surfshark-service",
                    displayName: "Surfshark",
                    interfaceType: "IPSec",
                    runtimeBSDName: "ipsec0",
                    connectionStatus: .connecting,
                    protocolHint: .ikev2
                )
            ],
            interfaces: [.init(bsdName: "ipsec0", isUp: true)]
        )
        let connected = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec0",
            services: [vpnService(runtimeBSDName: "ipsec0")],
            interfaces: [.init(bsdName: "ipsec0", isUp: true)]
        )
        let disconnected = resolve(
            services: [
                .init(
                    serviceID: "surfshark-service",
                    displayName: "Surfshark",
                    interfaceType: "IPSec",
                    bsdName: "ipsec0",
                    connectionStatus: .disconnected,
                    protocolHint: .ikev2
                )
            ]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_010)

        XCTAssertNotEqual(connecting.networkSignature, connected.networkSignature)
        XCTAssertNotEqual(connected.networkSignature, disconnected.networkSignature)
        XCTAssertTrue(
            MenuBarAuxiliaryMonitorState.shouldRefreshPublicNetworkAddress(
                force: false,
                networkSignature: connected.networkSignature,
                previousNetworkSignature: connecting.networkSignature,
                lastAttemptAt: now,
                hasPublicAddress: true,
                now: now
            )
        )
        XCTAssertFalse(
            MenuBarAuxiliaryMonitorState.shouldRefreshPublicNetworkAddress(
                force: false,
                networkSignature: connected.networkSignature,
                previousNetworkSignature: connected.networkSignature,
                lastAttemptAt: now,
                hasPublicAddress: true,
                now: now
            )
        )
    }

    func testPacketTunnelReconnectPreservesServiceIdentity() throws {
        let first = resolve(
            primaryServiceID: "packet-service",
            primaryInterfaceName: "utun4",
            services: [
                .init(
                    serviceID: "packet-service",
                    displayName: "Work VPN",
                    interfaceType: "PacketTunnel",
                    runtimeBSDName: "utun4",
                    connectionStatus: .connected
                )
            ],
            interfaces: [.init(bsdName: "utun4", isUp: true, ipv6Addresses: ["fd00::7"])]
        )
        let reconnected = resolve(
            primaryServiceID: "packet-service",
            primaryInterfaceName: "utun5",
            services: [
                .init(
                    serviceID: "packet-service",
                    displayName: "Work VPN",
                    interfaceType: "PacketTunnel",
                    runtimeBSDName: "utun5",
                    connectionStatus: .connected
                )
            ],
            interfaces: [.init(bsdName: "utun5", isUp: true, ipv6Addresses: ["fd00::8"])]
        )

        XCTAssertEqual(try XCTUnwrap(first.activeVPNTunnel).protocolKind, .packetTunnel)
        XCTAssertEqual(
            try XCTUnwrap(first.activeVPNTunnel).stableID,
            try XCTUnwrap(reconnected.activeVPNTunnel).stableID
        )
        XCTAssertEqual(try XCTUnwrap(reconnected.activeVPNTunnel).bsdName, "utun5")
    }

    func testPrimaryServiceAssociatesAnUnnamedRuntimeIPSecInterface() throws {
        let snapshot = resolve(
            primaryServiceID: "surfshark-service",
            primaryInterfaceName: "ipsec0",
            services: [
                .init(
                    serviceID: "surfshark-service",
                    displayName: "Surfshark",
                    interfaceType: "IPSec",
                    connectionStatus: .connected,
                    protocolHint: .ikev2
                )
            ],
            interfaces: [.init(bsdName: "ipsec0", isUp: true, ipv4Addresses: ["10.6.1.169"])]
        )

        let vpn = try XCTUnwrap(snapshot.activeVPNTunnel)
        XCTAssertEqual(vpn.bsdName, "ipsec0")
        XCTAssertEqual(vpn.displayName, "Surfshark · IKEv2")
        XCTAssertEqual(vpn.stableID, "service:surfshark-service")
    }

    func testDefaultRouteTunnelWinsWhenMultipleTunnelsExist() throws {
        let snapshot = resolve(
            primaryServiceID: "work-service",
            primaryInterfaceName: "utun5",
            services: [
                .init(
                    serviceID: "personal-service",
                    displayName: "Personal VPN",
                    interfaceType: "PacketTunnel",
                    runtimeBSDName: "utun4",
                    connectionStatus: .connected
                ),
                .init(
                    serviceID: "work-service",
                    displayName: "Work VPN",
                    interfaceType: "PacketTunnel",
                    runtimeBSDName: "utun5",
                    connectionStatus: .connected
                )
            ],
            interfaces: [
                .init(bsdName: "utun4", isUp: true),
                .init(bsdName: "utun5", isUp: true)
            ]
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.activeVPNTunnel).serviceID, "work-service")
        XCTAssertEqual(snapshot.additionalVPNTunnels.map(\.serviceID), ["personal-service"])
    }

    func testUnattributedTunnelDoesNotGuessProviderAndHasNoPersistentIdentity() throws {
        let snapshot = resolve(
            primaryInterfaceName: "utun4",
            interfaces: [.init(bsdName: "utun4", isUp: true, ipv4Addresses: ["10.10.0.2"])]
        )

        let vpn = try XCTUnwrap(snapshot.activeVPNTunnel)
        XCTAssertNil(vpn.providerName)
        XCTAssertNil(vpn.stableID)
        XCTAssertEqual(vpn.displayName, "VPN · Packet Tunnel")
        XCTAssertEqual(vpn.bsdName, "utun4")
    }

    func testIdleUTUNInterfacesDoNotCreateAPhantomVPN() {
        let snapshot = resolve(
            primaryInterfaceName: "en0",
            interfaces: [
                .init(bsdName: "en0", isUp: true, ipv4Addresses: ["192.168.1.24"]),
                .init(bsdName: "utun0", isUp: true, isPointToPoint: true),
                .init(bsdName: "utun1", isUp: true, isPointToPoint: true, ipv6Addresses: ["fe80::1"]),
                .init(bsdName: "utun2", isUp: true, isPointToPoint: true, ipv6Addresses: ["fe80::2"]),
            ]
        )

        XCTAssertEqual(snapshot.physicalTransport?.bsdName, "en0")
        XCTAssertNil(snapshot.activeVPNTunnel)
        XCTAssertTrue(snapshot.additionalVPNTunnels.isEmpty)
        XCTAssertTrue(snapshot.trafficSnapshot.detailOnlyTunnelInterfaceNames.isEmpty)
    }

    func testAddressClassifierDistinguishesPublicLocalTunnelAndLinkLocal() {
        XCTAssertEqual(
            NetworkTopologyResolver.classifyAddress("138.199.33.73", role: .physicalTransport),
            .publicInternet
        )
        XCTAssertEqual(
            NetworkTopologyResolver.classifyAddress("192.168.1.197", role: .physicalTransport),
            .localNetwork
        )
        XCTAssertEqual(
            NetworkTopologyResolver.classifyAddress("10.6.1.169", role: .vpnTunnel),
            .tunnel
        )
        XCTAssertEqual(
            NetworkTopologyResolver.classifyAddress("fe80::1", role: .physicalTransport),
            .linkLocal
        )
    }

    func testPublicSystemConfigurationIPSecTypeIsRecognizedWithoutGuessingIKEv2() {
        let service = NetworkTopologyServiceRecord(
            serviceID: "vpn-service",
            interfaceType: "IPSec",
            runtimeBSDName: "ipsec0"
        )

        XCTAssertTrue(NetworkTopologyResolver.isVPNService(service))
        XCTAssertEqual(
            NetworkTopologyResolver.protocolKind(
                interfaceType: service.interfaceType,
                bsdName: service.runtimeBSDName
            ),
            .ipsec
        )
    }

    func testExplicitServiceProtocolConfigurationCanConfirmIKEv2() {
        XCTAssertEqual(
            NetworkTopologyResolver.explicitProtocolHint(configurations: [
                ["Type": "IPSec"],
                ["VPNType": "IKEv2"]
            ]),
            .ikev2
        )
        XCTAssertEqual(
            NetworkTopologyResolver.explicitProtocolHint(configurations: [["Type": "IPSec"]]),
            .ipsec
        )
    }

    func testVirtualTunnelAndVMInterfacesDoNotLeakIntoPhysicalAddresses() {
        let snapshot = resolve(
            primaryServiceID: "wifi-service",
            primaryInterfaceName: "en0",
            services: [physicalService(serviceID: "wifi-service", name: "Wi-Fi", bsdName: "en0")],
            interfaces: [
                .init(bsdName: "en0", isUp: true, ipv4Addresses: ["192.168.1.197"]),
                .init(bsdName: "tun0", isUp: true, isPointToPoint: true, ipv4Addresses: ["10.0.0.2"]),
                .init(bsdName: "tap0", isUp: true, isPointToPoint: true, ipv4Addresses: ["10.0.1.2"]),
                .init(bsdName: "vnic0", isUp: true, ipv4Addresses: ["192.168.64.1"]),
                .init(bsdName: "vmnet1", isUp: true, ipv4Addresses: ["192.168.65.1"])
            ]
        )

        XCTAssertEqual(Set(snapshot.physicalAddresses.map(\.interfaceName)), ["en0"])
        XCTAssertEqual(
            Set(snapshot.tunnelAddresses.map(\.interfaceName)),
            Set(["tap0", "tun0"])
        )
    }

    func testConnectionSnapshotKeepsWiFiPowerLinkAndMultipleIPDetailsSeparate() {
        let topology = resolve(
            primaryServiceID: "wifi-service",
            primaryInterfaceName: "en9",
            wiFiInterfaceName: "en9",
            wiFiSSID: "Test WiFi",
            services: [
                .init(
                    serviceID: "wifi-service",
                    displayName: "Wi-Fi",
                    interfaceType: "IEEE80211",
                    bsdName: "en9",
                    runtimeBSDName: "en9",
                    dnsServers: ["192.168.50.1", "1.1.1.1", "2606:4700:4700::1111"],
                    gatewayOrRemoteAddress: "192.168.50.1"
                )
            ],
            interfaces: [
                .init(
                    bsdName: "en9",
                    isUp: true,
                    ipv4Addresses: ["192.168.50.53", "192.168.50.54"],
                    ipv6Addresses: ["2401:db00::53"]
                )
            ]
        )
        let native = nativeSnapshot(
            interfaceName: "en9",
            wiFiInterfaceName: "en9",
            isWiFiPoweredOn: true,
            ssid: "Test WiFi",
            ipv4SubnetMask: "255.255.255.0",
            ipv4Router: "192.168.50.1",
            ipv6Router: "fe80::1"
        )

        let connection = NetworkConnectionSnapshot.resolve(native: native, topology: topology)

        XCTAssertEqual(connection.connectionKind, .wifi)
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(connection.wifi?.powerState, .onConnected)
        XCTAssertEqual(connection.ipConfiguration.ipv4Addresses.count, 2)
        XCTAssertEqual(connection.ipConfiguration.ipv6Addresses, ["2401:db00::53"])
        XCTAssertEqual(connection.ipConfiguration.subnetMasks, ["255.255.255.0"])
        XCTAssertEqual(connection.ipConfiguration.ipv6Router, "fe80::1")
        XCTAssertEqual(connection.ipConfiguration.dnsServers.count, 3)
    }

    func testConnectionSnapshotUsesDefaultEthernetWithoutHardCodedBSDName() {
        let topology = resolve(
            primaryServiceID: "usb-lan-service",
            primaryInterfaceName: "en12",
            wiFiInterfaceName: "en0",
            services: [
                .init(
                    serviceID: "usb-lan-service",
                    displayName: "USB Ethernet",
                    interfaceType: "Ethernet",
                    bsdName: "en12",
                    runtimeBSDName: "en12",
                    gatewayOrRemoteAddress: "10.0.0.1"
                )
            ],
            interfaces: [
                .init(bsdName: "en0", isUp: true, ipv4Addresses: ["192.168.1.5"]),
                .init(bsdName: "en12", isUp: true, ipv4Addresses: ["10.0.0.5"])
            ]
        )
        let native = nativeSnapshot(
            interfaceName: "en12",
            wiFiInterfaceName: "en0",
            isWiFiPoweredOn: true,
            interfaceMTU: 1_500,
            linkSpeedMbps: 2_500
        )

        let connection = NetworkConnectionSnapshot.resolve(native: native, topology: topology)

        XCTAssertEqual(connection.connectionKind, .ethernet)
        XCTAssertEqual(connection.activeInterface?.bsdName, "en12")
        XCTAssertEqual(connection.ethernet?.mtu, 1_500)
        XCTAssertEqual(connection.ethernet?.linkSpeedMbps, 2_500)
        XCTAssertEqual(connection.ipConfiguration.ipv4Addresses, ["10.0.0.5"])
    }

    func testPoweredWiFiWithoutAPathIsNotReportedAsConnected() {
        let connection = NetworkConnectionSnapshot.resolve(
            native: nativeSnapshot(
                interfaceName: "en4",
                wiFiInterfaceName: "en4",
                isWiFiPoweredOn: true
            ),
            topology: nil
        )

        XCTAssertEqual(connection.connectionKind, .disconnected)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(connection.wifi?.powerState, .onDisconnected)
    }

    func testNativeWiFiPathRemainsConnectedWhileTopologyRefreshIsPending() {
        let connection = NetworkConnectionSnapshot.resolve(
            native: nativeSnapshot(
                interfaceName: "en4",
                wiFiInterfaceName: "en4",
                isWiFiPoweredOn: true,
                ssid: "Studio Wi-Fi"
            ),
            topology: nil
        )

        XCTAssertEqual(connection.connectionKind, .wifi)
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(connection.wifi?.powerState, .onConnected)
        XCTAssertEqual(connection.wifi?.ssid, "Studio Wi-Fi")
    }

    private func resolve(
        primaryServiceID: String? = nil,
        primaryInterfaceName: String? = nil,
        wiFiInterfaceName: String? = nil,
        wiFiSSID: String? = nil,
        services: [NetworkTopologyServiceRecord] = [],
        interfaces: [NetworkTopologyInterfaceRecord] = []
    ) -> NetworkTopologySnapshot {
        NetworkTopologyResolver.resolve(
            NetworkTopologyResolverInput(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                primaryServiceID: primaryServiceID,
                primaryInterfaceName: primaryInterfaceName,
                wiFiInterfaceName: wiFiInterfaceName,
                wiFiSSID: wiFiSSID,
                globalDNSServers: ["1.1.1.1"],
                services: services,
                interfaces: interfaces
            )
        )
    }

    private func physicalService(
        serviceID: String,
        name: String,
        bsdName: String
    ) -> NetworkTopologyServiceRecord {
        NetworkTopologyServiceRecord(
            serviceID: serviceID,
            displayName: name,
            interfaceType: "IEEE80211",
            bsdName: bsdName,
            runtimeBSDName: bsdName,
            dnsServers: ["192.168.1.1"]
        )
    }

    private func vpnService(runtimeBSDName: String) -> NetworkTopologyServiceRecord {
        NetworkTopologyServiceRecord(
            serviceID: "surfshark-service",
            displayName: "Surfshark",
            interfaceType: "IPSec",
            runtimeBSDName: runtimeBSDName,
            connectionStatus: .connected,
            protocolHint: .ikev2
        )
    }

    private func nativeSnapshot(
        interfaceName: String,
        wiFiInterfaceName: String?,
        isWiFiPoweredOn: Bool?,
        ssid: String? = nil,
        ipv4SubnetMask: String? = nil,
        ipv4Router: String? = nil,
        ipv6Router: String? = nil,
        interfaceMTU: Int? = nil,
        linkSpeedMbps: Int? = nil
    ) -> NativeNetworkInterfaceSnapshot {
        NativeNetworkInterfaceSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            interfaceName: interfaceName,
            wiFiInterfaceName: wiFiInterfaceName,
            isWiFiPoweredOn: isWiFiPoweredOn,
            hardwareAddress: "00:11:22:33:44:55",
            ssid: ssid,
            bssid: nil,
            countryCode: nil,
            wiFiPHYMode: "802.11ax",
            transmitRateMbps: 1_152,
            rssiDBm: -52,
            noiseDBm: -93,
            channelNumber: 40,
            channelBandGHz: 5,
            channelWidthMHz: 160,
            ipv4Addresses: [],
            ipv6Addresses: [],
            ipv4SubnetMask: ipv4SubnetMask,
            ipv4Router: ipv4Router,
            ipv6Router: ipv6Router,
            dnsServers: [],
            interfaceMTU: interfaceMTU,
            linkSpeedMbps: linkSpeedMbps
        )
    }
}
