import Foundation

enum NetworkTransportKind: String, Equatable, Sendable {
    case wiFi
    case ethernet
    case thunderbolt
    case other

    var displayName: String {
        switch self {
        case .wiFi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .thunderbolt: "Thunderbolt"
        case .other: "Network"
        }
    }
}

enum NetworkLinkState: String, Equatable, Sendable {
    case up
    case down
    case unknown
}

enum PhysicalConnectionKind: String, Equatable, Sendable {
    case wifi
    case ethernet
    case other
    case disconnected
}

enum WiFiPowerState: String, Equatable, Sendable {
    case onConnected
    case onDisconnected
    case off
    case changingToOn
    case changingToOff
    case unavailable
}

struct NetworkInterfaceIdentity: Equatable, Sendable {
    let displayName: String
    let bsdName: String
    let type: PhysicalConnectionKind
    let hardwareAddress: String?
}

struct WiFiConnectionDetails: Equatable, Sendable {
    let powerState: WiFiPowerState
    let ssid: String?
    let bssid: String?
    let phyMode: String?
    let bandGHz: Int?
    let transmitRateMbps: Double?
    let rssiDBm: Int?
    let noiseDBm: Int?
    let snrDB: Int?
    let channelNumber: Int?
    let channelWidthMHz: Int?
    let countryCode: String?
}

struct EthernetConnectionDetails: Equatable, Sendable {
    let linkActive: Bool
    let linkSpeedMbps: Int?
    let duplex: String?
    let mtu: Int?
    let mediaSubtype: String?
}

struct IPConfigurationDetails: Equatable, Sendable {
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
    let subnetMasks: [String]
    let ipv4Router: String?
    let ipv6Router: String?
    let dnsServers: [String]
}

struct NetworkConnectionSnapshot: Equatable, Sendable {
    let timestamp: Date
    let activeInterface: NetworkInterfaceIdentity?
    let connectionKind: PhysicalConnectionKind
    let isConnected: Bool
    let wifi: WiFiConnectionDetails?
    let ethernet: EthernetConnectionDetails?
    let ipConfiguration: IPConfigurationDetails
    let isVPNActive: Bool

    static func resolve(
        native: NativeNetworkInterfaceSnapshot?,
        topology: NetworkTopologySnapshot?
    ) -> NetworkConnectionSnapshot {
        let transport = topology?.physicalTransport
        let nativeIdentifiesWiFi = native?.interfaceName != nil
            && native?.interfaceName == native?.wiFiInterfaceName
        let nativeHasPath = native?.ssid?.isEmpty == false
            || native?.ipv4Addresses.isEmpty == false
            || native?.ipv6Addresses.isEmpty == false
        let kind: PhysicalConnectionKind = switch transport?.kind {
        case .wiFi: .wifi
        case .ethernet, .thunderbolt: .ethernet
        case .other: .other
        case nil: nativeIdentifiesWiFi && nativeHasPath ? .wifi : .disconnected
        }
        let nativeMatchesTransport = transport?.bsdName == native?.interfaceName
        let ipv4 = nonEmpty(
            transport?.ipv4Addresses,
            fallback: nativeMatchesTransport || transport == nil ? native?.ipv4Addresses : nil
        )
        let ipv6 = nonEmpty(
            transport?.ipv6Addresses,
            fallback: nativeMatchesTransport || transport == nil ? native?.ipv6Addresses : nil
        )
        let hasAddress = !ipv4.isEmpty || !ipv6.isEmpty
        let isConnected = switch kind {
        case .wifi:
            hasAddress || native?.ssid?.isEmpty == false || transport?.ssid?.isEmpty == false
        case .ethernet, .other:
            transport?.linkState == .up && hasAddress
        case .disconnected:
            false
        }
        let identityBSDName = transport?.bsdName ?? native?.interfaceName
        let identity = identityBSDName.map {
            NetworkInterfaceIdentity(
                displayName: transport?.displayName ?? (kind == .wifi ? "Wi-Fi" : "Network"),
                bsdName: $0,
                type: kind,
                hardwareAddress: nativeMatchesTransport || transport == nil
                    ? native?.hardwareAddress
                    : nil
            )
        }
        let wifi: WiFiConnectionDetails? = kind == .wifi || native?.wiFiInterfaceName != nil
            ? {
            let powerState: WiFiPowerState = switch native?.isWiFiPoweredOn {
            case true: kind == .wifi && isConnected ? .onConnected : .onDisconnected
            case false: .off
            case nil: .unavailable
            }
            return WiFiConnectionDetails(
                powerState: powerState,
                ssid: kind == .wifi ? (native?.ssid ?? transport?.ssid) : nil,
                bssid: kind == .wifi ? native?.bssid : nil,
                phyMode: kind == .wifi ? native?.wiFiPHYMode : nil,
                bandGHz: kind == .wifi ? native?.channelBandGHz : nil,
                transmitRateMbps: kind == .wifi ? native?.transmitRateMbps : nil,
                rssiDBm: kind == .wifi ? native?.rssiDBm : nil,
                noiseDBm: kind == .wifi ? native?.noiseDBm : nil,
                snrDB: kind == .wifi ? native?.signalToNoiseDB : nil,
                channelNumber: kind == .wifi ? native?.channelNumber : nil,
                channelWidthMHz: kind == .wifi ? native?.channelWidthMHz : nil,
                countryCode: kind == .wifi ? native?.countryCode : nil
            )
        }() : nil
        let ethernet = kind == .ethernet || kind == .other
            ? EthernetConnectionDetails(
                linkActive: isConnected,
                linkSpeedMbps: nativeMatchesTransport ? native?.linkSpeedMbps : nil,
                duplex: nil,
                mtu: nativeMatchesTransport ? native?.interfaceMTU : nil,
                mediaSubtype: transport?.kind.displayName
            )
            : nil
        let dns = nonEmpty(transport?.dnsServers, fallback: native?.dnsServers)
        let vpnIsActive = topology?.activeVPNTunnel.map {
            $0.status == .connected || $0.status == .connecting || $0.status == .reconnecting
        } ?? false

        return NetworkConnectionSnapshot(
            timestamp: native?.generatedAt ?? topology?.timestamp ?? Date(),
            activeInterface: identity,
            connectionKind: kind,
            isConnected: isConnected,
            wifi: wifi,
            ethernet: ethernet,
            ipConfiguration: IPConfigurationDetails(
                ipv4Addresses: ipv4,
                ipv6Addresses: ipv6,
                subnetMasks: nativeMatchesTransport || transport == nil
                    ? [native?.ipv4SubnetMask].compactMap { $0 }
                    : [],
                ipv4Router: transport?.gateway ?? native?.ipv4Router,
                ipv6Router: native?.ipv6Router,
                dnsServers: dns
            ),
            isVPNActive: vpnIsActive
        )
    }

    private static func nonEmpty(_ preferred: [String]?, fallback: [String]?) -> [String] {
        let preferred = preferred?.filter { !$0.isEmpty } ?? []
        return preferred.isEmpty ? (fallback?.filter { !$0.isEmpty } ?? []) : preferred
    }
}

enum VPNStatus: String, Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case disconnected
    case invalid
    case unknown
}

enum VPNProtocolKind: String, Equatable, Sendable {
    case ikev2
    case ipsec
    case packetTunnel
    case ppp
    case wireGuard
    case unknown

    var displayName: String {
        switch self {
        case .ikev2: "IKEv2"
        case .ipsec: "IPSec"
        case .packetTunnel: "Packet Tunnel"
        case .ppp: "PPP"
        case .wireGuard: "WireGuard"
        case .unknown: "VPN"
        }
    }
}

enum NetworkAddressClassification: String, Equatable, Sendable {
    case publicInternet
    case localNetwork
    case tunnel
    case loopback
    case linkLocal
    case unknown
}

enum NetworkAddressInterfaceRole: Equatable, Sendable {
    case physicalTransport
    case vpnTunnel
    case other
}

struct NetworkAddressSnapshot: Equatable, Sendable, Identifiable {
    let address: String
    let interfaceName: String
    let classification: NetworkAddressClassification

    var id: String { "\(interfaceName)|\(address)" }
}

struct PhysicalTransportSnapshot: Equatable, Sendable {
    let stableID: String
    let serviceID: String?
    let displayName: String
    let kind: NetworkTransportKind
    let bsdName: String
    let ssid: String?
    let linkState: NetworkLinkState
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
    let gateway: String?
    let dnsServers: [String]
    let isPrimaryTransport: Bool
}

struct VPNTunnelSnapshot: Equatable, Sendable, Identifiable {
    /// Nil means macOS exposed a runtime tunnel but no service identity that can
    /// survive a BSD-name change. Consumers must not persist the fallback `id`.
    let stableID: String?
    let serviceID: String?
    let displayName: String
    let providerName: String?
    let providerBundleIdentifier: String?
    let providerApplicationURL: URL?
    let protocolKind: VPNProtocolKind
    let bsdName: String
    let status: VPNStatus
    let tunnelIPv4: [String]
    let tunnelIPv6: [String]
    let scopedDNSServers: [String]
    let gatewayOrRemoteAddress: String?
    let isDefaultRoute: Bool
    let isSplitTunnel: Bool?

    var id: String { stableID ?? "runtime:\(bsdName)" }
}

struct PublicEndpointSnapshot: Equatable, Sendable {
    let ipv4: String?
    let ipv6: String?
    let countryCode: String?
    let countryName: String?
    let resolverTimestamp: Date?
    let networkSignature: String
}

struct NetworkDNSConfiguration: Equatable, Sendable {
    let globalServers: [String]
    let physicalServers: [String]
    let activeTunnelServers: [String]
}

enum TrafficAggregationPolicy: String, Equatable, Sendable {
    /// Use the established system-total source. Tunnel samples remain detail-only.
    case systemTotalOnly
    /// Sum physical uplinks only; never add the tunnel to the same total.
    case physicalUplinkOnly
}

struct NetworkTopologyTrafficSnapshot: Equatable, Sendable {
    let aggregationPolicy: TrafficAggregationPolicy
    let primaryInterfaceNames: [String]
    let detailOnlyTunnelInterfaceNames: [String]
}

struct NetworkTopologySnapshot: Equatable, Sendable {
    let timestamp: Date
    let physicalTransport: PhysicalTransportSnapshot?
    let activeVPNTunnel: VPNTunnelSnapshot?
    let additionalVPNTunnels: [VPNTunnelSnapshot]
    let publicEndpoint: PublicEndpointSnapshot?
    let physicalAddresses: [NetworkAddressSnapshot]
    let tunnelAddresses: [NetworkAddressSnapshot]
    let dnsConfiguration: NetworkDNSConfiguration
    let trafficSnapshot: NetworkTopologyTrafficSnapshot
    let networkSignature: String
}

/// Plain, injectable inputs to the topology resolver. The native adapter lives
/// in `NativeNetworkInterfaceService`; fixtures can construct this directly.
struct NetworkTopologyResolverInput: Equatable, Sendable {
    let timestamp: Date
    let primaryServiceID: String?
    let primaryInterfaceName: String?
    let wiFiInterfaceName: String?
    let wiFiSSID: String?
    let globalDNSServers: [String]
    let services: [NetworkTopologyServiceRecord]
    let interfaces: [NetworkTopologyInterfaceRecord]
    let publicEndpoint: PublicEndpointSnapshot?

    init(
        timestamp: Date,
        primaryServiceID: String? = nil,
        primaryInterfaceName: String? = nil,
        wiFiInterfaceName: String? = nil,
        wiFiSSID: String? = nil,
        globalDNSServers: [String] = [],
        services: [NetworkTopologyServiceRecord] = [],
        interfaces: [NetworkTopologyInterfaceRecord] = [],
        publicEndpoint: PublicEndpointSnapshot? = nil
    ) {
        self.timestamp = timestamp
        self.primaryServiceID = primaryServiceID
        self.primaryInterfaceName = primaryInterfaceName
        self.wiFiInterfaceName = wiFiInterfaceName
        self.wiFiSSID = wiFiSSID
        self.globalDNSServers = globalDNSServers
        self.services = services
        self.interfaces = interfaces
        self.publicEndpoint = publicEndpoint
    }
}

struct NetworkTopologyServiceRecord: Equatable, Sendable {
    let serviceID: String?
    let displayName: String?
    let interfaceType: String?
    let bsdName: String?
    let runtimeBSDName: String?
    let isEnabled: Bool
    let connectionStatus: VPNStatus
    let protocolHint: VPNProtocolKind?
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
    let dnsServers: [String]
    let gatewayOrRemoteAddress: String?
    let providerBundleIdentifier: String?
    let providerApplicationURL: URL?

    init(
        serviceID: String? = nil,
        displayName: String? = nil,
        interfaceType: String? = nil,
        bsdName: String? = nil,
        runtimeBSDName: String? = nil,
        isEnabled: Bool = true,
        connectionStatus: VPNStatus = .unknown,
        protocolHint: VPNProtocolKind? = nil,
        ipv4Addresses: [String] = [],
        ipv6Addresses: [String] = [],
        dnsServers: [String] = [],
        gatewayOrRemoteAddress: String? = nil,
        providerBundleIdentifier: String? = nil,
        providerApplicationURL: URL? = nil
    ) {
        self.serviceID = serviceID
        self.displayName = displayName
        self.interfaceType = interfaceType
        self.bsdName = bsdName
        self.runtimeBSDName = runtimeBSDName
        self.isEnabled = isEnabled
        self.connectionStatus = connectionStatus
        self.protocolHint = protocolHint
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
        self.dnsServers = dnsServers
        self.gatewayOrRemoteAddress = gatewayOrRemoteAddress
        self.providerBundleIdentifier = providerBundleIdentifier
        self.providerApplicationURL = providerApplicationURL
    }
}

struct NetworkTopologyInterfaceRecord: Equatable, Sendable {
    let bsdName: String
    let isUp: Bool
    let isPointToPoint: Bool
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]

    init(
        bsdName: String,
        isUp: Bool,
        isPointToPoint: Bool = false,
        ipv4Addresses: [String] = [],
        ipv6Addresses: [String] = []
    ) {
        self.bsdName = bsdName
        self.isUp = isUp
        self.isPointToPoint = isPointToPoint
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
    }
}

enum NetworkTopologyResolver {
    static func resolve(_ input: NetworkTopologyResolverInput) -> NetworkTopologySnapshot {
        let interfacesByName = Dictionary(
            uniqueKeysWithValues: input.interfaces.map { ($0.bsdName, $0) }
        )
        let vpnServices = input.services.filter(isVPNService)
        let runtimeTunnelNames = Set(input.interfaces
            .filter {
                isVPNInterfaceName($0.bsdName)
                    && shouldExposeUnattributedRuntimeTunnel(
                        $0,
                        primaryInterfaceName: input.primaryInterfaceName
                    )
            }
            .map(\.bsdName))
        let soleRuntimeTunnelName = vpnServices.count == 1
            && vpnServices.allSatisfy {
                normalizedName($0.runtimeBSDName) == nil && normalizedName($0.bsdName) == nil
            }
            && runtimeTunnelNames.count == 1
            ? runtimeTunnelNames.first
            : nil

        let serviceTunnels = vpnServices.compactMap { service -> VPNTunnelSnapshot? in
            let runtimeInterface = interface(
                for: service,
                in: interfacesByName,
                primaryServiceID: input.primaryServiceID,
                primaryInterfaceName: input.primaryInterfaceName,
                soleRuntimeTunnelName: soleRuntimeTunnelName
            )
            guard shouldExposeVPN(service: service, runtimeInterface: runtimeInterface) else {
                return nil
            }
            return makeTunnel(
                service: service,
                interface: runtimeInterface,
                primaryServiceID: input.primaryServiceID,
                primaryInterfaceName: input.primaryInterfaceName
            )
        }
        let serviceTunnelNames = Set(serviceTunnels.map(\.bsdName))
        let allTunnelNames = serviceTunnelNames.union(runtimeTunnelNames)
        let attributedNames = Set(serviceTunnels.map(\.bsdName))
        let unattributedTunnels: [VPNTunnelSnapshot] = allTunnelNames
            .subtracting(attributedNames)
            .sorted()
            .compactMap { name -> VPNTunnelSnapshot? in
                guard let interface = interfacesByName[name] else { return nil }
                return makeUnattributedTunnel(
                    interface: interface,
                    primaryInterfaceName: input.primaryInterfaceName
                )
            }
        let allTunnels = (serviceTunnels + unattributedTunnels)
            .sorted(by: tunnelSort)
        let activeTunnel = allTunnels.first
        let additionalTunnels = Array(allTunnels.dropFirst())

        let physicalTransport = makePhysicalTransport(
            services: input.services.filter { !isVPNService($0) },
            interfacesByName: interfacesByName,
            excludedTunnelNames: allTunnelNames,
            primaryInterfaceName: input.primaryInterfaceName,
            wiFiInterfaceName: input.wiFiInterfaceName,
            wiFiSSID: input.wiFiSSID,
            globalDNSServers: input.globalDNSServers
        )

        let physicalAddresses = input.interfaces
            .filter { !allTunnelNames.contains($0.bsdName) && isPhysicalInterfaceName($0.bsdName) }
            .flatMap { addressSnapshots(for: $0, role: .physicalTransport) }
            .sorted { $0.id < $1.id }
        let tunnelAddresses = allTunnels
            .flatMap { tunnel in
                addressSnapshots(
                    ipv4: tunnel.tunnelIPv4,
                    ipv6: tunnel.tunnelIPv6,
                    interfaceName: tunnel.bsdName,
                    role: .vpnTunnel
                )
            }
            .sorted { $0.id < $1.id }
        let signature = networkSignature(
            primaryServiceID: input.primaryServiceID,
            primaryInterfaceName: input.primaryInterfaceName,
            physicalTransport: physicalTransport,
            activeTunnel: activeTunnel,
            additionalTunnels: additionalTunnels
        )

        return NetworkTopologySnapshot(
            timestamp: input.timestamp,
            physicalTransport: physicalTransport,
            activeVPNTunnel: activeTunnel,
            additionalVPNTunnels: additionalTunnels,
            publicEndpoint: input.publicEndpoint,
            physicalAddresses: physicalAddresses,
            tunnelAddresses: tunnelAddresses,
            dnsConfiguration: NetworkDNSConfiguration(
                globalServers: normalizedAddresses(input.globalDNSServers),
                physicalServers: physicalTransport?.dnsServers ?? [],
                activeTunnelServers: activeTunnel?.scopedDNSServers ?? []
            ),
            trafficSnapshot: NetworkTopologyTrafficSnapshot(
                aggregationPolicy: .systemTotalOnly,
                primaryInterfaceNames: physicalTransport.map { [$0.bsdName] } ?? [],
                detailOnlyTunnelInterfaceNames: allTunnels.map { $0.bsdName }
            ),
            networkSignature: signature
        )
    }

    static func isVPNService(_ service: NetworkTopologyServiceRecord) -> Bool {
        if service.protocolHint != nil { return true }
        if let interfaceType = normalizedName(service.interfaceType)?.lowercased() {
            switch interfaceType {
            case "ipsec", "ppp", "vpn", "packet-tunnel", "packettunnel", "wireguard":
                return true
            default:
                break
            }
        }
        return [service.runtimeBSDName, service.bsdName]
            .compactMap(normalizedName)
            .contains(where: isVPNInterfaceName)
    }

    static func protocolKind(
        interfaceType: String?,
        bsdName: String?,
        explicitHint: VPNProtocolKind? = nil
    ) -> VPNProtocolKind {
        if let explicitHint { return explicitHint }
        let type = normalizedName(interfaceType)?.lowercased()
        if type == "ipsec" { return .ipsec }
        if type == "ppp" { return .ppp }
        if type == "packet-tunnel" || type == "packettunnel" { return .packetTunnel }
        if type == "wireguard" { return .wireGuard }
        let bsdName = normalizedName(bsdName)
        if bsdName?.hasPrefix("ipsec") == true { return .ipsec }
        if bsdName?.hasPrefix("utun") == true { return .packetTunnel }
        if bsdName?.hasPrefix("ppp") == true { return .ppp }
        return .unknown
    }

    static func stableVPNIdentity(
        serviceID: String?,
        providerBundleIdentifier: String?,
        displayName: String?,
        protocolKind: VPNProtocolKind
    ) -> String? {
        if let serviceID = normalizedName(serviceID) {
            return "service:\(serviceID)"
        }
        if let bundleIdentifier = normalizedName(providerBundleIdentifier) {
            return "provider:\(bundleIdentifier):\(protocolKind.rawValue)"
        }
        if let displayName = normalizedName(displayName), displayName != "vpn" {
            return "service-name:\(displayName):\(protocolKind.rawValue)"
        }
        return nil
    }

    static func classifyAddress(
        _ address: String,
        role: NetworkAddressInterfaceRole
    ) -> NetworkAddressClassification {
        guard !address.isEmpty else { return .unknown }
        if role == .vpnTunnel { return .tunnel }
        let normalized = address.lowercased().split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        if normalized == "::1" || normalized.hasPrefix("127.") { return .loopback }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("169.254.") { return .linkLocal }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") || isPrivateIPv4(normalized) {
            return .localNetwork
        }
        if isIPv4(normalized) || normalized.contains(":") { return .publicInternet }
        return .unknown
    }

    static func explicitProtocolHint(configuration: [String: Any]) -> VPNProtocolKind? {
        let values = ["VPNType", "ProtocolType", "Type"].compactMap { configuration[$0] as? String }
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "ikev2" { return .ikev2 }
            if normalized == "wireguard" { return .wireGuard }
            if normalized == "ipsec" { return .ipsec }
            if normalized == "ppp" { return .ppp }
            if normalized == "packet-tunnel" || normalized == "packettunnel" { return .packetTunnel }
        }
        return nil
    }

    static func explicitProtocolHint(configurations: [[String: Any]]) -> VPNProtocolKind? {
        let hints = configurations.compactMap(explicitProtocolHint(configuration:))
        // A generic IPSec interface configuration must not hide an explicitly
        // declared IKEv2 protocol configuration for the same service.
        return hints.first(where: { $0 == .ikev2 }) ?? hints.first
    }

    private static func makeTunnel(
        service: NetworkTopologyServiceRecord,
        interface: NetworkTopologyInterfaceRecord?,
        primaryServiceID: String?,
        primaryInterfaceName: String?
    ) -> VPNTunnelSnapshot {
        let bsdName = interface?.bsdName
            ?? normalizedName(service.runtimeBSDName)
            ?? normalizedName(service.bsdName)
            ?? "vpn"
        let protocolKind = protocolKind(
            interfaceType: service.interfaceType,
            bsdName: bsdName,
            explicitHint: service.protocolHint
        )
        let status: VPNStatus
        if service.connectionStatus != .unknown {
            status = service.connectionStatus
        } else if interface?.isUp == true {
            status = .connected
        } else if !service.isEnabled {
            status = .disconnected
        } else {
            status = .unknown
        }
        let isDefaultRoute = normalizedName(service.serviceID) == normalizedName(primaryServiceID)
            || bsdName == normalizedName(primaryInterfaceName)
        let displayName = displayName(for: service, protocolKind: protocolKind)
        let ipv4 = normalizedAddresses(interface?.ipv4Addresses ?? service.ipv4Addresses)
        let ipv6 = normalizedAddresses(interface?.ipv6Addresses ?? service.ipv6Addresses)

        return VPNTunnelSnapshot(
            stableID: stableVPNIdentity(
                serviceID: service.serviceID,
                providerBundleIdentifier: service.providerBundleIdentifier,
                displayName: service.displayName,
                protocolKind: protocolKind
            ),
            serviceID: normalizedName(service.serviceID),
            displayName: displayName,
            providerName: normalizedName(service.displayName),
            providerBundleIdentifier: normalizedName(service.providerBundleIdentifier),
            providerApplicationURL: service.providerApplicationURL,
            protocolKind: protocolKind,
            bsdName: bsdName,
            status: status,
            tunnelIPv4: ipv4,
            tunnelIPv6: ipv6,
            scopedDNSServers: normalizedAddresses(service.dnsServers),
            gatewayOrRemoteAddress: normalizedName(service.gatewayOrRemoteAddress),
            isDefaultRoute: isDefaultRoute,
            // Public SystemConfiguration state exposes the default route, but
            // does not prove a per-destination split-tunnel policy.
            isSplitTunnel: isDefaultRoute ? false : nil
        )
    }

    private static func makeUnattributedTunnel(
        interface: NetworkTopologyInterfaceRecord,
        primaryInterfaceName: String?
    ) -> VPNTunnelSnapshot {
        let protocolKind = protocolKind(interfaceType: nil, bsdName: interface.bsdName)
        return VPNTunnelSnapshot(
            stableID: nil,
            serviceID: nil,
            displayName: "VPN · \(protocolKind.displayName)",
            providerName: nil,
            providerBundleIdentifier: nil,
            providerApplicationURL: nil,
            protocolKind: protocolKind,
            bsdName: interface.bsdName,
            status: interface.isUp ? .connected : .unknown,
            tunnelIPv4: normalizedAddresses(interface.ipv4Addresses),
            tunnelIPv6: normalizedAddresses(interface.ipv6Addresses),
            scopedDNSServers: [],
            gatewayOrRemoteAddress: nil,
            isDefaultRoute: interface.bsdName == normalizedName(primaryInterfaceName),
            isSplitTunnel: nil
        )
    }

    /// macOS often leaves idle utun interfaces up for system services. They
    /// are not evidence of a connected VPN unless the route selects one or it
    /// carries a usable tunnel address. Identified VPN services bypass this
    /// fallback entirely.
    private static func shouldExposeUnattributedRuntimeTunnel(
        _ interface: NetworkTopologyInterfaceRecord,
        primaryInterfaceName: String?
    ) -> Bool {
        let name = interface.bsdName.lowercased()
        guard name.hasPrefix("utun") else { return true }
        guard interface.isUp else { return false }
        if interface.bsdName == normalizedName(primaryInterfaceName) {
            return true
        }
        return normalizedAddresses(interface.ipv4Addresses + interface.ipv6Addresses)
            .contains {
                switch classifyAddress($0, role: .physicalTransport) {
                case .linkLocal, .loopback, .unknown:
                    false
                case .localNetwork, .publicInternet, .tunnel:
                    true
                }
            }
    }

    private static func makePhysicalTransport(
        services: [NetworkTopologyServiceRecord],
        interfacesByName: [String: NetworkTopologyInterfaceRecord],
        excludedTunnelNames: Set<String>,
        primaryInterfaceName: String?,
        wiFiInterfaceName: String?,
        wiFiSSID: String?,
        globalDNSServers: [String]
    ) -> PhysicalTransportSnapshot? {
        let candidates = services.compactMap { service -> (NetworkTopologyServiceRecord, NetworkTopologyInterfaceRecord)? in
            guard let interface = interface(for: service, in: interfacesByName),
                  !excludedTunnelNames.contains(interface.bsdName),
                  isPhysicalInterfaceName(interface.bsdName) else {
                return nil
            }
            return (service, interface)
        }
        let fallbackInterfaces = interfacesByName.values
            .filter { !excludedTunnelNames.contains($0.bsdName) && isPhysicalInterfaceName($0.bsdName) }
            .map { (NetworkTopologyServiceRecord(bsdName: $0.bsdName), $0) }
        let ordered = (candidates.isEmpty ? fallbackInterfaces : candidates).sorted { lhs, rhs in
            let lhsPrimary = lhs.1.bsdName == normalizedName(primaryInterfaceName)
            let rhsPrimary = rhs.1.bsdName == normalizedName(primaryInterfaceName)
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            if lhs.1.isUp != rhs.1.isUp { return lhs.1.isUp }
            return lhs.1.bsdName < rhs.1.bsdName
        }
        guard let (service, interface) = ordered.first else { return nil }
        let isWiFi = interface.bsdName == normalizedName(wiFiInterfaceName)
        let kind = transportKind(interfaceType: service.interfaceType, isWiFi: isWiFi)
        let displayName = normalizedName(service.displayName) ?? kind.displayName
        let dnsServers = normalizedAddresses(service.dnsServers).isEmpty
            ? normalizedAddresses(globalDNSServers)
            : normalizedAddresses(service.dnsServers)

        return PhysicalTransportSnapshot(
            stableID: normalizedName(service.serviceID).map { "service:\($0)" } ?? "transport:\(interface.bsdName)",
            serviceID: normalizedName(service.serviceID),
            displayName: displayName,
            kind: kind,
            bsdName: interface.bsdName,
            ssid: isWiFi ? normalizedName(wiFiSSID) : nil,
            linkState: interface.isUp ? .up : .down,
            ipv4Addresses: normalizedAddresses(interface.ipv4Addresses),
            ipv6Addresses: normalizedAddresses(interface.ipv6Addresses),
            gateway: normalizedName(service.gatewayOrRemoteAddress),
            dnsServers: dnsServers,
            isPrimaryTransport: true
        )
    }

    private static func interface(
        for service: NetworkTopologyServiceRecord,
        in interfacesByName: [String: NetworkTopologyInterfaceRecord],
        primaryServiceID: String? = nil,
        primaryInterfaceName: String? = nil,
        soleRuntimeTunnelName: String? = nil
    ) -> NetworkTopologyInterfaceRecord? {
        for name in [service.runtimeBSDName, service.bsdName].compactMap(normalizedName) {
            if let interface = interfacesByName[name] { return interface }
        }
        if normalizedName(service.serviceID) == normalizedName(primaryServiceID),
           let primaryInterfaceName = normalizedName(primaryInterfaceName),
           isVPNInterfaceName(primaryInterfaceName),
           let interface = interfacesByName[primaryInterfaceName] {
            return interface
        }
        if let soleRuntimeTunnelName,
           let interface = interfacesByName[soleRuntimeTunnelName] {
            return interface
        }
        return nil
    }

    private static func shouldExposeVPN(
        service: NetworkTopologyServiceRecord,
        runtimeInterface: NetworkTopologyInterfaceRecord?
    ) -> Bool {
        switch service.connectionStatus {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnecting, .disconnected, .invalid, .unknown:
            break
        }

        // A saved VPN profile alone is not an active tunnel. Retain a service
        // while macOS still exposes its live tunnel so disconnecting can settle
        // cleanly without losing the runtime identity mid-transition.
        if let runtimeBSDName = normalizedName(service.runtimeBSDName),
           isVPNInterfaceName(runtimeBSDName) {
            return true
        }
        return runtimeInterface.map { isVPNInterfaceName($0.bsdName) } ?? false
    }

    private static func addressSnapshots(
        for interface: NetworkTopologyInterfaceRecord,
        role: NetworkAddressInterfaceRole
    ) -> [NetworkAddressSnapshot] {
        addressSnapshots(
            ipv4: interface.ipv4Addresses,
            ipv6: interface.ipv6Addresses,
            interfaceName: interface.bsdName,
            role: role
        )
    }

    private static func addressSnapshots(
        ipv4: [String],
        ipv6: [String],
        interfaceName: String,
        role: NetworkAddressInterfaceRole
    ) -> [NetworkAddressSnapshot] {
        normalizedAddresses(ipv4 + ipv6).map { address in
            NetworkAddressSnapshot(
                address: address,
                interfaceName: interfaceName,
                classification: classifyAddress(address, role: role)
            )
        }
    }

    private static func displayName(
        for service: NetworkTopologyServiceRecord,
        protocolKind: VPNProtocolKind
    ) -> String {
        if let name = normalizedName(service.displayName) {
            return "\(name) · \(protocolKind.displayName)"
        }
        return "VPN · \(protocolKind.displayName)"
    }

    private static func transportKind(interfaceType: String?, isWiFi: Bool) -> NetworkTransportKind {
        if isWiFi { return .wiFi }
        return switch normalizedName(interfaceType)?.lowercased() {
        case "ieee80211", "wifi", "wi-fi": .wiFi
        case "thunderbolt": .thunderbolt
        case "ethernet": .ethernet
        default: .other
        }
    }

    private static func tunnelSort(_ lhs: VPNTunnelSnapshot, _ rhs: VPNTunnelSnapshot) -> Bool {
        if lhs.isDefaultRoute != rhs.isDefaultRoute { return lhs.isDefaultRoute }
        if lhs.status == .connected && rhs.status != .connected { return true }
        if rhs.status == .connected && lhs.status != .connected { return false }
        return lhs.id < rhs.id
    }

    private static func networkSignature(
        primaryServiceID: String?,
        primaryInterfaceName: String?,
        physicalTransport: PhysicalTransportSnapshot?,
        activeTunnel: VPNTunnelSnapshot?,
        additionalTunnels: [VPNTunnelSnapshot]
    ) -> String {
        let tunnelIDs = ([activeTunnel] + additionalTunnels)
            .compactMap { tunnel -> String? in
                guard let tunnel else { return nil }
                return [
                    tunnel.stableID ?? "runtime",
                    tunnel.bsdName,
                    tunnel.status.rawValue
                ].joined(separator: ":")
            }
            .sorted()
        return [
            normalizedName(primaryServiceID) ?? "",
            normalizedName(primaryInterfaceName) ?? "",
            physicalTransport?.stableID ?? "",
            tunnelIDs.joined(separator: ",")
        ].joined(separator: "|")
    }

    private static func normalizedAddresses(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalizedName))).sorted()
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isVPNInterfaceName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("ipsec") || name.hasPrefix("utun") || name.hasPrefix("ppp")
            || name.hasPrefix("tun") || name.hasPrefix("tap")
    }

    private static func isPhysicalInterfaceName(_ name: String) -> Bool {
        let name = name.lowercased()
        if ["ipsec", "utun", "ppp", "tun", "tap", "vnic", "vmnet"].contains(where: name.hasPrefix) {
            return false
        }
        return name.hasPrefix("en") || name.hasPrefix("bridge") == false && name.hasPrefix("lo") == false
            && name.hasPrefix("awdl") == false && name.hasPrefix("llw") == false
            && name.hasPrefix("gif") == false
            && name.hasPrefix("stf") == false
    }

    private static func isIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch parts[0] {
        case 10:
            return true
        case 172:
            return (16...31).contains(parts[1])
        case 192:
            return parts[1] == 168
        default:
            return false
        }
    }
}
