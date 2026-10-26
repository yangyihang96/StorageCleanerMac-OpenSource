import Darwin
import Foundation

/// D140: the addresses iStat Menus 7.30 lists for an interface, in its
/// network menu's IP section (`-[NetworkMenu privateAddresses]`) and the
/// interface submenu's (`-[NetworkMenu updateInterfaceSubmenu]`), from what
/// `-[BBRStatisticsNetwork ipAddressInfo:]` reads with `getifaddrs`:
/// - the interface's IPv4 addresses, then its IPv6 addresses, each family in
///   `getifaddrs` order;
/// - an address with a point-to-point destination is left out (a tunnel's
///   or a PPP link's: `IFF_POINTOPOINT` with a destination address);
/// - a deprecated IPv6 address is left out;
/// - an IPv6 address is listed when it is secured, iStat's "Secured" switch
///   (on by default). A temporary or a DHCPv6 address alone is not: its
///   "Temporary" and "Dynamic" switches are off by default and we have
///   neither. One without any of the three is never listed.
/// The IPv6 flags are the kernel's (`SIOCGIFAFLAG_IN6`, the request iStat
/// sends); an address whose flags cannot be read is not listed, as in iStat.
enum NetworkAddressListing {
    struct Entry: Equatable, Sendable {
        let address: String
        let isIPv6: Bool
        let hasDestination: Bool
        /// The `IN6_IFF_*` flags; nil for IPv4 or when the kernel did not
        /// answer.
        let ipv6Flags: Int32?

        init(address: String, isIPv6: Bool, hasDestination: Bool = false, ipv6Flags: Int32? = nil) {
            self.address = address
            self.isIPv6 = isIPv6
            self.hasDestination = hasDestination
            self.ipv6Flags = ipv6Flags
        }
    }

    /// `SIOCGIFAFLAG_IN6`: `_IOWR('i', 73, struct in6_ifreq)`, the 288-byte
    /// request iStat sends (0xc1206949). The interface's name leads it, the
    /// address follows at 16, and the flags come back there as an `int`.
    static let addressFlagsRequest: UInt = 0xc120_6949
    static let addressFlagsRequestSize = 288
    static let addressFlagsOffset = Int(IFNAMSIZ)

    static func isListed(_ entry: Entry) -> Bool {
        guard !entry.hasDestination else { return false }
        guard entry.isIPv6 else { return true }
        guard let flags = entry.ipv6Flags, flags & IN6_IFF_DEPRECATED == 0 else { return false }
        return flags & IN6_IFF_SECURED != 0
    }

    /// The listed addresses: IPv4 first, then IPv6, each once.
    static func listed(_ entries: [Entry]) -> [String] {
        var seen = Set<String>()
        return (entries.filter { !$0.isIPv6 } + entries.filter(\.isIPv6))
            .filter(isListed)
            .map(\.address)
            .filter { seen.insert($0).inserted }
    }

    /// Several interfaces' listed addresses in iStat's order
    /// (`privateAddresses` collects the two families apart and joins them):
    /// every IPv4 address, then every IPv6 address, each once.
    static func ordered(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return (addresses.filter { !$0.contains(":") } + addresses.filter { $0.contains(":") })
            .filter { seen.insert($0).inserted }
    }

    /// The network menu's IP section: the connection's listed addresses and
    /// each VPN's, in iStat's order; a tunnel without a list adds none.
    static func menuAddresses(connection: [String], tunnels: [VPNTunnelSnapshot]) -> [String] {
        ordered(connection + tunnels.flatMap { $0.listedAddresses ?? [] })
    }

    /// iStat's destination test: a point-to-point interface's destination
    /// address, of the same family for IPv6.
    static func hasDestination(_ entry: ifaddrs) -> Bool {
        guard entry.ifa_flags & UInt32(IFF_POINTOPOINT) != 0,
              let destination = entry.ifa_dstaddr,
              let address = entry.ifa_addr else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET: return true
        case AF_INET6: return Int32(destination.pointee.sa_family) == AF_INET6
        default: return false
        }
    }

    /// Reads one IPv6 address's flags through `socket` (an `AF_INET6`
    /// datagram socket); nil when the kernel does not answer. Read-only.
    static func ipv6Flags(socket: Int32, interfaceName: String, address: UnsafePointer<sockaddr>) -> Int32? {
        guard socket >= 0, Int32(address.pointee.sa_family) == AF_INET6 else { return nil }
        var request = [UInt8](repeating: 0, count: addressFlagsRequestSize)
        return request.withUnsafeMutableBytes { buffer -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            let name = Array(interfaceName.utf8.prefix(Int(IFNAMSIZ) - 1))
            buffer.copyBytes(from: name)
            memcpy(base + addressFlagsOffset, address, MemoryLayout<sockaddr_in6>.size)
            guard ioctl(socket, addressFlagsRequest, base) == 0 else { return nil }
            return base.load(fromByteOffset: addressFlagsOffset, as: Int32.self)
        }
    }
}
