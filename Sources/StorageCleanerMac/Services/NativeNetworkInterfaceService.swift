import CoreWLAN
import Combine
import Darwin
import Foundation
import SystemConfiguration

struct NativeNetworkInterfaceSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let interfaceName: String?
    let wiFiInterfaceName: String?
    let isWiFiPoweredOn: Bool?
    let hardwareAddress: String?
    let ssid: String?
    let bssid: String?
    let countryCode: String?
    let wiFiPHYMode: String?
    let transmitRateMbps: Double?
    let rssiDBm: Int?
    let noiseDBm: Int?
    let channelNumber: Int?
    let channelBandGHz: Int?
    let channelWidthMHz: Int?
    let ipv4Addresses: [String]
    let ipv6Addresses: [String]
    let ipv4SubnetMask: String?
    let ipv4Router: String?
    let ipv6Router: String?
    let dnsServers: [String]
    let interfaceMTU: Int?
    let linkSpeedMbps: Int?

    var signalToNoiseDB: Int? {
        guard let rssiDBm, let noiseDBm else { return nil }
        return rssiDBm - noiseDBm
    }
}

enum NativeNetworkInterfaceControlError: LocalizedError, Equatable, Sendable {
    case interfaceUnavailable
    case verificationFailed(expected: Bool, actual: Bool)

    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable:
            "No controllable Wi-Fi interface is available."
        case .verificationFailed:
            "macOS did not confirm the requested Wi-Fi power state."
        }
    }
}

enum NativeNetworkInterfaceService {
    /// Reads the wireless interface itself, independently of the default route.
    /// No scan, SSID lookup, or location permission is needed for RSSI.
    static func statusWiFiSnapshot(now: Date = Date()) -> MenuBarWiFiStatusSnapshot {
        guard let interface = wiFiInterface(using: CWWiFiClient.shared()) else {
            return .init(sampledAt: now, state: .unknown)
        }
        guard interface.powerOn() else {
            return .init(sampledAt: now, state: .off)
        }
        let rssi = interface.rssiValue()
        // CoreWLAN uses zero for both errors and non-association. Only a
        // separate, inactive interface observation confirms disconnection.
        let state = MenuBarWiFiSignalState.resolve(
            rssi: rssi,
            serviceActive: interface.serviceActive(),
            hasChannel: interface.wlanChannel() != nil
        )
        return .init(sampledAt: now, state: state)
    }

    static func snapshot(now: Date = Date()) -> NativeNetworkInterfaceSnapshot {
        let client = CWWiFiClient.shared()
        let interface = wiFiInterface(using: client)
        let interfaceName = resolvedInterfaceName(
            coreWLANInterfaceName: interface?.interfaceName,
            primaryIPv4InterfaceName: dynamicStoreDictionary(
                key: "State:/Network/Global/IPv4"
            )["PrimaryInterface"] as? String
        )
        let addresses = addresses(for: interfaceName)
        let globalDetails = globalNetworkDetails(for: interfaceName)
        let selectedWiFiInterface = interface?.interfaceName == interfaceName ? interface : nil
        let channel = selectedWiFiInterface?.wlanChannel()

        return NativeNetworkInterfaceSnapshot(
            generatedAt: now,
            interfaceName: interfaceName,
            wiFiInterfaceName: interface?.interfaceName,
            isWiFiPoweredOn: interface.map { $0.powerOn() },
            hardwareAddress: selectedWiFiInterface?.hardwareAddress() ?? addresses.hardwareAddress,
            ssid: selectedWiFiInterface?.ssid(),
            bssid: selectedWiFiInterface?.bssid(),
            countryCode: selectedWiFiInterface?.countryCode(),
            wiFiPHYMode: selectedWiFiInterface.flatMap {
                wiFiPHYMode(rawValue: $0.activePHYMode().rawValue)
            },
            transmitRateMbps: normalizedPositive(selectedWiFiInterface?.transmitRate()),
            rssiDBm: normalizedNegative(selectedWiFiInterface?.rssiValue()),
            noiseDBm: normalizedNegative(selectedWiFiInterface?.noiseMeasurement()),
            channelNumber: channel.map { Int($0.channelNumber) },
            channelBandGHz: channel.flatMap { channelBandGHz(rawValue: $0.channelBand.rawValue) },
            channelWidthMHz: channel.flatMap { channelWidthMHz($0.channelWidth) },
            ipv4Addresses: addresses.ipv4,
            ipv6Addresses: addresses.ipv6,
            ipv4SubnetMask: addresses.ipv4SubnetMask,
            ipv4Router: globalDetails.ipv4Router,
            ipv6Router: globalDetails.ipv6Router,
            dnsServers: globalDetails.dnsServers,
            interfaceMTU: addresses.mtu,
            linkSpeedMbps: addresses.linkSpeedMbps
        )
    }

    /// Reads public SystemConfiguration and interface state into a topology that
    /// keeps the physical transport separate from VPN runtime interfaces.
    static func topologySnapshot(now: Date = Date()) -> NetworkTopologySnapshot {
        let client = CWWiFiClient.shared()
        let wiFi = wiFiInterface(using: client)
        let globalIPv4 = dynamicStoreDictionary(key: "State:/Network/Global/IPv4")
        let globalDNS = dynamicStoreDictionary(key: "State:/Network/Global/DNS")

        return NetworkTopologyResolver.resolve(
            NetworkTopologyResolverInput(
                timestamp: now,
                primaryServiceID: globalIPv4["PrimaryService"] as? String,
                primaryInterfaceName: globalIPv4["PrimaryInterface"] as? String,
                wiFiInterfaceName: wiFi?.interfaceName,
                wiFiSSID: wiFi?.ssid(),
                globalDNSServers: stringArray(globalDNS["ServerAddresses"]),
                services: topologyServiceRecords(),
                interfaces: topologyInterfaceRecords()
            )
        )
    }

    /// Changes only the Wi-Fi interface selected by CoreWLAN, then verifies the
    /// result. No caller-controlled BSD name crosses this control boundary.
    static func setDefaultWiFiPower(_ isOn: Bool) throws -> Bool {
        let client = CWWiFiClient.shared()
        guard let interface = wiFiInterface(using: client) else {
            throw NativeNetworkInterfaceControlError.interfaceUnavailable
        }
        try interface.setPower(isOn)

        for attempt in 0..<5 {
            let actual = interface.powerOn()
            if actual == isOn { return actual }
            if attempt < 4 { usleep(100_000) }
        }
        throw NativeNetworkInterfaceControlError.verificationFailed(
            expected: isOn,
            actual: interface.powerOn()
        )
    }

    private static func wiFiInterface(using client: CWWiFiClient) -> CWInterface? {
        if let interface = client.interface() {
            return interface
        }
        guard let interfaceName = client.interfaceNames()?.sorted().first else { return nil }
        return client.interface(withName: interfaceName)
    }

    private static func addresses(
        for interfaceName: String?
    ) -> (
        ipv4: [String],
        ipv6: [String],
        ipv4SubnetMask: String?,
        hardwareAddress: String?,
        mtu: Int?,
        linkSpeedMbps: Int?
    ) {
        guard let interfaceName else { return ([], [], nil, nil, nil, nil) }
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return ([], [], nil, nil, nil, nil)
        }
        defer { freeifaddrs(firstAddress) }

        var ipv4: [String] = []
        var ipv6: [String] = []
        var ipv4SubnetMask: String?
        var hardwareAddress: String?
        var mtu: Int?
        var linkSpeedMbps: Int?
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            guard let name = address.pointee.ifa_name,
                  String(cString: name) == interfaceName,
                  let socketAddress = address.pointee.ifa_addr else { continue }

            if let rawData = address.pointee.ifa_data {
                let interfaceData = rawData.assumingMemoryBound(to: if_data.self).pointee
                if interfaceData.ifi_mtu > 0 {
                    mtu = mtu ?? Int(interfaceData.ifi_mtu)
                }
                if interfaceData.ifi_baudrate > 0 {
                    linkSpeedMbps = linkSpeedMbps
                        ?? Int(interfaceData.ifi_baudrate / 1_000_000)
                }
            }

            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_LINK {
                hardwareAddress = hardwareAddress ?? linkLayerAddress(from: socketAddress)
                continue
            }
            guard family == AF_INET || family == AF_INET6 else { continue }

            guard let value = numericHost(from: socketAddress) else { continue }
            if family == AF_INET {
                ipv4.append(value)
                if ipv4SubnetMask == nil, let netmask = address.pointee.ifa_netmask {
                    ipv4SubnetMask = numericHost(from: netmask)
                }
            } else {
                ipv6.append(value.components(separatedBy: "%").first ?? value)
            }
        }

        return (
            Array(Set(ipv4)).sorted(),
            Array(Set(ipv6)).sorted(),
            ipv4SubnetMask,
            hardwareAddress,
            mtu,
            linkSpeedMbps
        )
    }

    private static func topologyServiceRecords() -> [NetworkTopologyServiceRecord] {
        guard let preferences = SCPreferencesCreate(
            nil,
            "StorageCleanerMac.NetworkTopology" as CFString,
            nil
        ), let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return []
        }

        return services.map { service in
            let serviceID = SCNetworkServiceGetServiceID(service) as String?
            let interface = SCNetworkServiceGetInterface(service)
            let interfaceType = interface.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            let bsdName = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
            let ipv4 = serviceID.map { dynamicStoreDictionary(key: "State:/Network/Service/\($0)/IPv4") } ?? [:]
            let ipv6 = serviceID.map { dynamicStoreDictionary(key: "State:/Network/Service/\($0)/IPv6") } ?? [:]
            let dns = serviceID.map { dynamicStoreDictionary(key: "State:/Network/Service/\($0)/DNS") } ?? [:]

            return NetworkTopologyServiceRecord(
                serviceID: serviceID,
                displayName: SCNetworkServiceGetName(service) as String?,
                interfaceType: interfaceType,
                bsdName: bsdName,
                runtimeBSDName: dynamicInterfaceName(ipv4: ipv4, ipv6: ipv6),
                isEnabled: SCNetworkServiceGetEnabled(service),
                connectionStatus: vpnConnectionStatus(
                    serviceID: serviceID,
                    isVPN: NetworkTopologyResolver.isVPNService(
                        NetworkTopologyServiceRecord(
                            serviceID: serviceID,
                            interfaceType: interfaceType,
                            bsdName: bsdName,
                            runtimeBSDName: dynamicInterfaceName(ipv4: ipv4, ipv6: ipv6)
                        )
                    )
                ),
                protocolHint: explicitVPNProtocolHint(for: service, interface: interface),
                ipv4Addresses: stringArray(ipv4["Addresses"]),
                ipv6Addresses: stringArray(ipv6["Addresses"]),
                dnsServers: stringArray(dns["ServerAddresses"]),
                gatewayOrRemoteAddress: (ipv4["Router"] as? String) ?? (ipv6["Router"] as? String)
            )
        }
    }

    private static func topologyInterfaceRecords() -> [NetworkTopologyInterfaceRecord] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        struct Accumulator {
            var isUp = false
            var isPointToPoint = false
            var ipv4: [String] = []
            var ipv6: [String] = []
        }

        var records: [String: Accumulator] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            guard let name = address.pointee.ifa_name else { continue }
            let interfaceName = String(cString: name)
            let flags = UInt32(address.pointee.ifa_flags)
            var record = records[interfaceName] ?? Accumulator()
            record.isUp = record.isUp || flags & UInt32(IFF_UP) != 0
            record.isPointToPoint = record.isPointToPoint || flags & UInt32(IFF_POINTOPOINT) != 0

            if let socketAddress = address.pointee.ifa_addr {
                let family = Int32(socketAddress.pointee.sa_family)
                if family == AF_INET, let value = numericHost(from: socketAddress) {
                    record.ipv4.append(value)
                } else if family == AF_INET6, let value = numericHost(from: socketAddress) {
                    record.ipv6.append(value.components(separatedBy: "%").first ?? value)
                }
            }
            records[interfaceName] = record
        }

        return records.keys.sorted().compactMap { name in
            guard let record = records[name] else { return nil }
            return NetworkTopologyInterfaceRecord(
                bsdName: name,
                isUp: record.isUp,
                isPointToPoint: record.isPointToPoint,
                ipv4Addresses: Array(Set(record.ipv4)).sorted(),
                ipv6Addresses: Array(Set(record.ipv6)).sorted()
            )
        }
    }

    static func resolvedInterfaceName(
        coreWLANInterfaceName: String?,
        primaryIPv4InterfaceName: String?
    ) -> String? {
        for name in [primaryIPv4InterfaceName, coreWLANInterfaceName] {
            guard let name else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func linkLayerAddress(from address: UnsafePointer<sockaddr>) -> String? {
        let linkAddress = UnsafeRawPointer(address)
            .assumingMemoryBound(to: sockaddr_dl.self)
            .pointee
        guard linkAddress.sdl_alen > 0,
              let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }

        let bytes = UnsafeRawPointer(address)
            .advanced(by: dataOffset + Int(linkAddress.sdl_nlen))
            .assumingMemoryBound(to: UInt8.self)
        return (0..<Int(linkAddress.sdl_alen))
            .map { String(format: "%02x", bytes[$0]) }
            .joined(separator: ":")
    }

    private static func numericHost(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func globalNetworkDetails(
        for interfaceName: String?
    ) -> (ipv4Router: String?, ipv6Router: String?, dnsServers: [String]) {
        let ipv4 = dynamicStoreDictionary(key: "State:/Network/Global/IPv4")
        let ipv6 = dynamicStoreDictionary(key: "State:/Network/Global/IPv6")
        let dns = dynamicStoreDictionary(key: "State:/Network/Global/DNS")

        let ipv4Matches = interfaceName == nil || ipv4["PrimaryInterface"] as? String == interfaceName
        let ipv6Matches = interfaceName == nil || ipv6["PrimaryInterface"] as? String == interfaceName
        let dnsServers = (dns["ServerAddresses"] as? [String] ?? [])
            .filter { !$0.isEmpty }

        return (
            ipv4Matches ? ipv4["Router"] as? String : nil,
            ipv6Matches ? ipv6["Router"] as? String : nil,
            Array(Set(dnsServers)).sorted()
        )
    }

    private static func dynamicInterfaceName(
        ipv4: [String: Any],
        ipv6: [String: Any]
    ) -> String? {
        ["InterfaceName", "PrimaryInterface", "DeviceName", "BSDName"].lazy
            .compactMap { key in
                (ipv4[key] as? String) ?? (ipv6[key] as? String)
            }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        Array(Set((value as? [String] ?? []).filter { !$0.isEmpty })).sorted()
    }

    private static func explicitVPNProtocolHint(
        for service: SCNetworkService,
        interface: SCNetworkInterface?
    ) -> VPNProtocolKind? {
        let interfaceConfiguration = interface.flatMap {
            SCNetworkInterfaceGetConfiguration($0) as? [String: Any]
        }
        let configurations = ([interfaceConfiguration].compactMap { $0 })
            + vpnProtocolConfigurations(for: service)
        return NetworkTopologyResolver.explicitProtocolHint(configurations: configurations)
    }

    private static func vpnProtocolConfigurations(for service: SCNetworkService) -> [[String: Any]] {
        guard let protocols = SCNetworkServiceCopyProtocols(service) as? [SCNetworkProtocol] else {
            return []
        }
        return protocols.compactMap { protocolConfiguration in
            guard let type = SCNetworkProtocolGetProtocolType(protocolConfiguration) as String?,
                  ["IPSec", "PPP"].contains(type),
                  let configuration = SCNetworkProtocolGetConfiguration(protocolConfiguration)
                    as? [String: Any] else {
                return nil
            }
            return configuration
        }
    }

    private static func vpnConnectionStatus(serviceID: String?, isVPN: Bool) -> VPNStatus {
        guard isVPN,
              let serviceID,
              let connection = SCNetworkConnectionCreateWithServiceID(
                  nil,
                  serviceID as CFString,
                  nil,
                  nil
              ) else {
            return .unknown
        }

        switch SCNetworkConnectionGetStatus(connection) {
        case .invalid:
            return .invalid
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        default:
            return .unknown
        }
    }

    private static func dynamicStoreDictionary(key: String) -> [String: Any] {
        SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any] ?? [:]
    }

    private static func normalizedPositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalizedNegative(_ value: Int?) -> Int? {
        guard let value, value < 0 else { return nil }
        return value
    }

    private static func channelWidthMHz(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz:
            20
        case .width40MHz:
            40
        case .width80MHz:
            80
        case .width160MHz:
            160
        case .widthUnknown:
            nil
        @unknown default:
            nil
        }
    }

    static func wiFiPHYMode(rawValue: Int) -> String? {
        switch rawValue {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n"
        case 5: "802.11ac"
        case 6: "802.11ax"
        case 7: "802.11be"
        default: nil
        }
    }

    static func channelBandGHz(rawValue: Int) -> Int? {
        switch rawValue {
        case 1: 2
        case 2: 5
        case 3: 6
        default: nil
        }
    }
}

enum NetworkControlError: Error, Equatable, Sendable {
    case unavailable
    case verificationFailed
    case operationRejected
}

@MainActor
final class WiFiPowerControlCoordinator: ObservableObject {
    typealias RequestSender = @Sendable (Bool) async -> Result<Bool, NetworkControlError>

    static let shared = WiFiPowerControlCoordinator()

    @Published private(set) var confirmedPower: Bool?
    @Published private(set) var requestedPower: Bool?
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: NetworkControlError?
    @Published private(set) var completionGeneration = 0

    private let requestSender: RequestSender
    private var pendingTarget: Bool?
    private var pendingRequestID: UUID?
    private var latestRequestID: UUID?
    private var workerTask: Task<Void, Never>?

    init(requestSender: RequestSender? = nil) {
        self.requestSender = requestSender ?? Self.sendRequest
    }

    func synchronize(confirmedPower: Bool?) {
        guard !isApplying else { return }
        self.confirmedPower = confirmedPower
    }

    func request(_ enabled: Bool) {
        let requestID = UUID()
        latestRequestID = requestID
        pendingRequestID = requestID
        pendingTarget = enabled
        requestedPower = enabled
        lastError = nil
        isApplying = true
        PerformanceTelemetry.signposter.emitEvent("WiFiPowerRequested")
        guard workerTask == nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.drainRequests()
        }
    }

    func displayedPower(fallback: Bool?) -> Bool? {
        requestedPower ?? confirmedPower ?? fallback
    }

    func displayedState(base: WiFiPowerState) -> WiFiPowerState {
        guard isApplying, let requestedPower else { return base }
        return requestedPower ? .changingToOn : .changingToOff
    }

    private func drainRequests() async {
        while let target = pendingTarget,
              let requestID = pendingRequestID {
            pendingTarget = nil
            pendingRequestID = nil
            let result = await requestSender(target)

            guard requestID == latestRequestID else { continue }
            switch result {
            case .success(let actual):
                confirmedPower = actual
                if actual == target {
                    lastError = nil
                    PerformanceTelemetry.signposter.emitEvent("WiFiPowerConfirmed")
                } else {
                    lastError = .verificationFailed
                    PerformanceTelemetry.signposter.emitEvent("WiFiPowerFailed")
                }
            case .failure(let error):
                lastError = error
                PerformanceTelemetry.signposter.emitEvent("WiFiPowerFailed")
            }
            requestedPower = nil
            isApplying = false
            completionGeneration &+= 1
        }
        workerTask = nil
    }

    private static func sendRequest(_ enabled: Bool) async -> Result<Bool, NetworkControlError> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try NativeNetworkInterfaceService.setDefaultWiFiPower(enabled))
            } catch NativeNetworkInterfaceControlError.interfaceUnavailable {
                return .failure(.unavailable)
            } catch NativeNetworkInterfaceControlError.verificationFailed {
                return .failure(.verificationFailed)
            } catch {
                return .failure(.operationRejected)
            }
        }.value
    }
}
