#if DEBUG
import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D140: iStat Menus 7.30's IP sections (`BBRNetworkMenuIPSection`): the
/// addresses it lists (`-[BBRStatisticsNetwork ipAddressInfo:]`,
/// `-[NetworkMenu privateAddresses]`), the section's own measure
/// (`intrinsicContentSize`) and its items (`drawRect:`, `mouseDown:`).
/// Fixtures and documentation addresses only (RFC 5737, RFC 3849); the one
/// live read asks the kernel for the loopback address's flags. Renders
/// offscreen; the copy and the refresh fail the test if anything calls
/// them. No pasteboard, panel, window, lookup or network change.
@MainActor
final class MiniWindowIStatIPSectionTests: XCTestCase {
    typealias Listing = NetworkAddressListing
    typealias Entry = NetworkAddressListing.Entry

    /// iStat's rules: an IPv4 address without a point-to-point destination;
    /// an IPv6 address that is secured, not deprecated and without a
    /// destination (its "Temporary" and "Dynamic" switches are off by
    /// default). IPv4 first, then IPv6, each family in its order, once.
    func testTheListKeepsIStatsAddresses() {
        let secured = IN6_IFF_SECURED
        XCTAssertTrue(Listing.isListed(Entry(address: "192.0.2.35", isIPv6: false)))
        XCTAssertFalse(Listing.isListed(Entry(address: "198.51.100.2", isIPv6: false, hasDestination: true)))
        XCTAssertTrue(Listing.isListed(Entry(address: "2001:db8::35", isIPv6: true, ipv6Flags: secured)))
        XCTAssertTrue(Listing.isListed(Entry(address: "2001:db8::36", isIPv6: true,
                                             ipv6Flags: secured | IN6_IFF_AUTOCONF)))
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::37", isIPv6: true,
                                              ipv6Flags: secured | IN6_IFF_DEPRECATED)))
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::38", isIPv6: true,
                                              ipv6Flags: IN6_IFF_AUTOCONF | IN6_IFF_TEMPORARY)), "temporary")
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::39", isIPv6: true, ipv6Flags: IN6_IFF_DYNAMIC)),
                       "DHCPv6")
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::3a", isIPv6: true, ipv6Flags: 0)))
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::3b", isIPv6: true)), "flags not read")
        XCTAssertFalse(Listing.isListed(Entry(address: "2001:db8::3c", isIPv6: true, hasDestination: true,
                                              ipv6Flags: secured)))

        let entries = [
            Entry(address: "2001:db8::35", isIPv6: true, ipv6Flags: secured),
            Entry(address: "192.0.2.35", isIPv6: false),
            Entry(address: "2001:db8::38", isIPv6: true, ipv6Flags: IN6_IFF_TEMPORARY),
            Entry(address: "198.51.100.7", isIPv6: false),
            Entry(address: "192.0.2.35", isIPv6: false),
        ]
        XCTAssertEqual(Listing.listed(entries), ["192.0.2.35", "198.51.100.7", "2001:db8::35"])
        XCTAssertEqual(Listing.listed([]), [])
        // Several interfaces (`privateAddresses` collects the families apart):
        // every IPv4 address, then every IPv6 one.
        XCTAssertEqual(Listing.ordered(["192.0.2.35", "2001:db8::35", "198.51.100.7", "2001:db8::35"]),
                       ["192.0.2.35", "198.51.100.7", "2001:db8::35"])
    }

    /// The network menu's section lists the connection's addresses and each
    /// VPN's, every IPv4 address first; a tunnel without a list adds none.
    func testTheMenuListsEveryConnectedInterface() throws {
        let tunnel = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: .networkVPNSystem))
        var listing = tunnel
        listing.listedAddresses = ["2001:db8:5::1", "198.51.100.20"]
        var unread = tunnel
        unread.listedAddresses = nil
        XCTAssertEqual(Listing.menuAddresses(connection: Self.demoAddresses, tunnels: [listing, unread, tunnel]),
                       ["192.0.2.35", "198.51.100.20", "2001:db8::35", "2001:db8:5::1"])
        XCTAssertEqual(Listing.menuAddresses(connection: [], tunnels: [tunnel]), [], "the demo tunnels list none")
        XCTAssertEqual(Listing.menuAddresses(connection: Self.demoAddresses, tunnels: []), Self.demoAddresses)
    }

    /// iStat's destination test: the interface is point-to-point and has a
    /// destination, of the same family for IPv6. A broadcast interface's
    /// broadcast address (`ifa_broadaddr` is `ifa_dstaddr`) is no destination.
    func testTheDestinationTestIsIStats() {
        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        var otherIPv4 = ipv4
        var ipv6 = sockaddr_in6()
        ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        ipv6.sin6_family = sa_family_t(AF_INET6)
        var otherIPv6 = ipv6

        func hasDestination(_ address: UnsafeMutablePointer<sockaddr>, _ destination: UnsafeMutablePointer<sockaddr>?,
                            pointToPoint: Bool) -> Bool {
            var entry = ifaddrs()
            entry.ifa_flags = UInt32(IFF_UP) | (pointToPoint ? UInt32(IFF_POINTOPOINT) : 0)
            entry.ifa_addr = address
            entry.ifa_dstaddr = destination
            return Listing.hasDestination(entry)
        }
        withUnsafeMutablePointer(to: &ipv4) { ipv4Pointer in
            withUnsafeMutablePointer(to: &otherIPv4) { otherIPv4Pointer in
                withUnsafeMutablePointer(to: &ipv6) { ipv6Pointer in
                    withUnsafeMutablePointer(to: &otherIPv6) { otherIPv6Pointer in
                        let v4 = UnsafeMutableRawPointer(ipv4Pointer).assumingMemoryBound(to: sockaddr.self)
                        let v4Other = UnsafeMutableRawPointer(otherIPv4Pointer).assumingMemoryBound(to: sockaddr.self)
                        let v6 = UnsafeMutableRawPointer(ipv6Pointer).assumingMemoryBound(to: sockaddr.self)
                        let v6Other = UnsafeMutableRawPointer(otherIPv6Pointer).assumingMemoryBound(to: sockaddr.self)
                        XCTAssertTrue(hasDestination(v4, v4Other, pointToPoint: true))
                        XCTAssertFalse(hasDestination(v4, nil, pointToPoint: true))
                        XCTAssertFalse(hasDestination(v4, v4Other, pointToPoint: false), "a broadcast address")
                        XCTAssertTrue(hasDestination(v6, v6Other, pointToPoint: true))
                        XCTAssertFalse(hasDestination(v6, v4Other, pointToPoint: true), "another family")
                        XCTAssertFalse(hasDestination(v6, v6Other, pointToPoint: false))
                    }
                }
            }
        }
    }

    /// What the reading keeps of an address for the list: an IPv6 address
    /// without its scope, whether it has a destination, and no flags
    /// without a socket.
    func testTheReadingKeepsWhatTheListNeeds() {
        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        var ipv6 = sockaddr_in6()
        ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        ipv6.sin6_family = sa_family_t(AF_INET6)
        withUnsafeMutablePointer(to: &ipv4) { ipv4Pointer in
            withUnsafeMutablePointer(to: &ipv6) { ipv6Pointer in
                let v4 = UnsafeMutableRawPointer(ipv4Pointer).assumingMemoryBound(to: sockaddr.self)
                let v6 = UnsafeMutableRawPointer(ipv6Pointer).assumingMemoryBound(to: sockaddr.self)
                var entry = ifaddrs()
                entry.ifa_flags = UInt32(IFF_UP)
                entry.ifa_addr = v6
                XCTAssertEqual(NativeNetworkInterfaceService.listingEntry(entry, value: "fe80::1%en0", socket: -1,
                                                                          interfaceName: "en0"),
                               Listing.Entry(address: "fe80::1", isIPv6: true))
                entry.ifa_addr = v4
                XCTAssertEqual(NativeNetworkInterfaceService.listingEntry(entry, value: "192.0.2.35", socket: -1,
                                                                          interfaceName: "en0"),
                               Listing.Entry(address: "192.0.2.35", isIPv6: false))
                entry.ifa_flags |= UInt32(IFF_POINTOPOINT)
                entry.ifa_dstaddr = v4
                XCTAssertEqual(NativeNetworkInterfaceService.listingEntry(entry, value: "192.0.2.35", socket: -1,
                                                                          interfaceName: "ppp0"),
                               Listing.Entry(address: "192.0.2.35", isIPv6: false, hasDestination: true))
            }
        }
        // With a socket the kernel's flags come with it (the loopback
        // address on lo0; only whether it answered is compared).
        let flagsSocket = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(flagsSocket, 0)
        defer { if flagsSocket >= 0 { close(flagsSocket) } }
        var loopback = sockaddr_in6()
        loopback.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        loopback.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &loopback.sin6_addr), 1)
        withUnsafeMutablePointer(to: &loopback) { pointer in
            var entry = ifaddrs()
            entry.ifa_flags = UInt32(IFF_UP) | UInt32(IFF_LOOPBACK)
            entry.ifa_addr = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self)
            XCTAssertNotNil(NativeNetworkInterfaceService.listingEntry(entry, value: "::1", socket: flagsSocket,
                                                                       interfaceName: "lo0").ipv6Flags)
        }
    }

    /// The flags come from the request iStat sends, `SIOCGIFAFLAG_IN6`
    /// (`_IOWR('i', 73, struct in6_ifreq)`): read-only, 288 bytes, the name
    /// first and the address at 16, where the flags come back. The kernel
    /// answers for the loopback address; an IPv4 address or no socket asks
    /// nothing.
    func testTheFlagsRequestIsTheKernels() throws {
        let request = UInt(0xC000_0000) | UInt(288 & 0x1FFF) << 16 | UInt(UInt8(ascii: "i")) << 8 | 73
        XCTAssertEqual(Listing.addressFlagsRequest, request)
        XCTAssertEqual(Listing.addressFlagsRequest, 0xC120_6949)
        XCTAssertEqual(Listing.addressFlagsRequestSize, 288)
        XCTAssertEqual(Listing.addressFlagsOffset, 16)
        XCTAssertLessThanOrEqual(Listing.addressFlagsOffset + MemoryLayout<sockaddr_in6>.size, 288)

        let flagsSocket = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(flagsSocket, 0)
        defer { if flagsSocket >= 0 { close(flagsSocket) } }
        var loopback = sockaddr_in6()
        loopback.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        loopback.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &loopback.sin6_addr), 1)
        let flags = withUnsafePointer(to: &loopback) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Listing.ipv6Flags(socket: flagsSocket, interfaceName: "lo0", address: $0)
            }
        }
        XCTAssertNotNil(flags, "the kernel answers for ::1 on lo0")
        let noSocket = withUnsafePointer(to: &loopback) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Listing.ipv6Flags(socket: -1, interfaceName: "lo0", address: $0)
            }
        }
        XCTAssertNil(noSocket)
        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        let ipv4Flags = withUnsafePointer(to: &ipv4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Listing.ipv6Flags(socket: flagsSocket, interfaceName: "lo0", address: $0)
            }
        }
        XCTAssertNil(ipv4Flags)
    }

    /// iStat's measure: from 22, each address's height in the value font at
    /// W − 16, then 5; 27 without an address, 15 a line. The longest IPv6
    /// form fits the network menu's 269 pt; on a 228 pt submenu (196) a
    /// long one takes two lines.
    func testTheSectionMeasuresLikeIStat() {
        typealias Geometry = GeekIStatInterfaceGeometry
        XCTAssertEqual(GeekIStatIPSectionGeometry.networkPageSectionWidth, 285)
        XCTAssertEqual(Geometry.addressTextWidth(sectionWidth: 285), 269)
        XCTAssertEqual(Geometry.sectionWidth(pageWidth: 228), 212)
        XCTAssertEqual(GeekIStatIPSectionGeometry.networkPageHeight(addresses: []), 27)
        XCTAssertEqual(GeekIStatIPSectionGeometry.networkPageHeight(addresses: ["192.0.2.35"]), 42)
        XCTAssertEqual(GeekIStatIPSectionGeometry.networkPageHeight(addresses: Self.demoAddresses), 57)
        XCTAssertEqual(GeekIStatIPSectionGeometry.networkPageHeight(addresses: [Self.longestAddress]), 42)
        XCTAssertEqual(Geometry.addressHeight(Self.longAddress, textWidth: 196), 30)
        XCTAssertEqual(Geometry.addressHeight(Self.longAddress, textWidth: 241), 15)
        XCTAssertEqual(Geometry.addressSectionHeight(addresses: ["192.0.2.35", Self.longAddress], textWidth: 196), 72)
        // The one-line count agrees.
        XCTAssertEqual((1...3).map { Geometry.addressSectionHeight(addresses: Array(repeating: "192.0.2.35", count: $0),
                                                                    textWidth: 269) },
                       (1...3).map(Geometry.addressSectionHeight(addresses:)))
    }

    /// The sections render as tall as they measure: the network menu's
    /// sections without an address, with the demo's two and the public
    /// one's flag; an interface submenu where a long address wraps.
    func testRenderedSectionsMatchTheirMeasure() throws {
        let width = GeekIStatIPSectionGeometry.networkPageSectionWidth
        let cases: [([String], String?)] = [([], nil), (Self.demoAddresses, nil), (Self.demoAddresses, "🇦🇺")]
        for (addresses, flag) in cases {
            let bitmap = try Self.render(GeekIStatIPSection(title: "IP 地址", addresses: addresses, flag: flag),
                                         width: width)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2,
                           GeekIStatIPSectionGeometry.networkPageHeight(addresses: addresses), accuracy: 0.5,
                           "\(addresses) \(flag ?? "")")
        }
        let submenu = GeekIStatInterfaceGeometry.sectionWidth(pageWidth: 228)
        let wrapped = ["192.0.2.35", Self.longAddress]
        let bitmap = try Self.render(GeekIStatIPSection(title: "IP 地址", addresses: wrapped), width: submenu)
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 72, accuracy: 0.5, "the long address takes two lines")
    }

    /// An interface's submenu measures its addresses at its own width, so a
    /// page with a long address is as tall as it renders.
    func testTheConnectionPageCountsAWrappedAddress() throws {
        var native = MiniWindowDemoData.networkInterfaceSnapshot
        native.listedAddresses = ["192.0.2.35", Self.longAddress]
        let connection = NetworkConnectionSnapshot.resolve(native: native, topology: nil)
        let model = GeekIStatInterfaceModel(connection: connection)
        XCTAssertEqual(model.addresses, ["192.0.2.35", Self.longAddress])
        let size = GeekNetworkTertiaryView.preferredSize(for: connection)
        XCTAssertEqual(model.sectionHeights(pageWidth: size.width)[2],
                       GeekIStatInterfaceGeometry.addressSectionHeight(
                           addresses: model.addresses,
                           textWidth: size.width - 32))
        let page = GeekNetworkTertiaryView(snapshot: native, topology: nil, refresh: {
            XCTFail("A render must never refresh")
        })
        let bitmap = try Self.render(page, width: size.width, insetPage: true)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5)
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, size.height, accuracy: 0.5)
        try Self.export(name: "l3-network-connection-wrapped-address") { mode in
            try Self.render(page, width: size.width, mode: mode, insetPage: true)
        }
    }

    /// The public section follows the lookup switch: off, there is no
    /// section (iStat's public addresses switched off); on, the addresses it
    /// has, IPv4 then IPv6, under the flag of the IPv4 address's country.
    func testThePublicSectionFollowsTheLookupSwitch() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let snapshot = MiniWindowDemoData.publicNetworkAddressSnapshot
        let section = GeekPublicNetworkAddressSection(snapshot: snapshot, isLoading: false, refresh: {
            XCTFail("A render must never refresh")
        })
        let width = GeekIStatIPSectionGeometry.networkPageSectionWidth

        XCTAssertNil(defaults.object(forKey: PublicNetworkConsent.addressKey), "the default: on")
        let on = try Self.render(section.defaultAppStorage(defaults), width: width)
        XCTAssertEqual(CGFloat(on.pixelsHigh) / 2, 57, accuracy: 0.5)
        // The demo's country (AU) gives the flag in its rect.
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        let card = try XCTUnwrap(on.colorAt(x: Int((width - 70) * 2), y: Int(25 * 2))?.usingColorSpace(.sRGB))
        var flagPixels = 0
        for y in stride(from: CGFloat(3.5), through: 20.5, by: 1) {
            for x in stride(from: width - 29.5, through: width - 10.5, by: 1) {
                let pixel = try XCTUnwrap(on.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
                if distance(pixel, card) > 0.2 { flagPixels += 1 }
            }
        }
        XCTAssertGreaterThan(flagPixels, 40, "the public section's flag")
        defaults.set(false, forKey: PublicNetworkConsent.addressKey)
        XCTAssertEqual(try Self.renderedHeight(section.defaultAppStorage(defaults), width: width), 0,
                       "no section while the lookup is off")

        XCTAssertEqual(GeekPublicNetworkAddressSection.addresses(snapshot), ["203.0.113.35", "2001:db8:1::35"])
        XCTAssertEqual(GeekPublicNetworkAddressSection.addresses(nil), [])
        let ipv4Only = PublicNetworkAddressSnapshot(generatedAt: MiniWindowDemoData.referenceDate,
                                                    ipv4Address: "203.0.113.35", ipv6Address: "",
                                                    ipv4CountryCode: nil, ipv6CountryCode: "AU")
        XCTAssertEqual(GeekPublicNetworkAddressSection.addresses(ipv4Only), ["203.0.113.35"])
        XCTAssertEqual(PublicNetworkAddressService.flagEmoji(forCountryCode: "AU"), "🇦🇺")
        // The IPv4 address's country, else the IPv6 one's.
        let twoCountries = PublicNetworkAddressSnapshot(generatedAt: MiniWindowDemoData.referenceDate,
                                                        ipv4Address: "203.0.113.35", ipv6Address: "2001:db8:1::35",
                                                        ipv4CountryCode: "AU", ipv6CountryCode: "NZ")
        XCTAssertEqual(GeekPublicNetworkAddressSection.flag(twoCountries), "🇦🇺")
        XCTAssertEqual(GeekPublicNetworkAddressSection.flag(ipv4Only), "🇦🇺")
        XCTAssertNil(GeekPublicNetworkAddressSection.flag(nil))
    }

    /// iStat's items: the flag in (W − 30, 2, 20, 20); the refresh icon in
    /// (W − 24, 4, 16, 16), or (W − 50, 4, 16, 16) beside a flag, drawn only
    /// while the section is hovered; the label W − 50 wide beside a flag.
    /// Unhovered, the refresh rect shows the card only.
    func testTheItemsSitWhereIStatDrawsThem() throws {
        typealias Geometry = GeekIStatIPSectionGeometry
        XCTAssertEqual([Geometry.flagFontSize, Geometry.flagSize, Geometry.flagTop, Geometry.flagTrailing],
                       [18, 20, 2, 10])
        XCTAssertEqual([Geometry.refreshSize, Geometry.refreshTop, Geometry.refreshTrailing,
                        Geometry.refreshTrailingBesideFlag], [16, 4, 8, 34])
        XCTAssertEqual(Geometry.flagLabelTrailing, 50 - GeekIStatTextSectionGeometry.leading)

        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let width = Geometry.networkPageSectionWidth
        let bitmap = try Self.render(GeekIStatIPSection(title: "公共 IP 地址", addresses: Self.demoAddresses,
                                                        flag: "🇦🇺", refresh: { XCTFail("never refreshed") }),
                                     width: width)
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        // The card's own color on each row, right of the label.
        var flagPixels = 0
        for y in stride(from: CGFloat(3.5), through: 20.5, by: 1) {
            let card = try color(width - 70, y)
            for x in stride(from: width - 29.5, through: width - 10.5, by: 1) {
                if try distance(color(x, y), card) > 0.2 { flagPixels += 1 }
            }
        }
        XCTAssertGreaterThan(flagPixels, 40, "the flag in its 20 pt rect")
        // Its pixels lie in that rect, from near its leading and top edges
        // (the glyph's own margins): none further right or lower.
        let reference = try color(width - 70, 25)
        var box = (minX: CGFloat.infinity, maxX: -CGFloat.infinity, minY: CGFloat.infinity, maxY: -CGFloat.infinity)
        for py in 4...53 {
            for px in Int((width - 40.5) * 2)...Int((width - 8.5) * 2) {
                let pixel = try XCTUnwrap(bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                guard distance(pixel, reference) > 0.2 else { continue }
                let x = CGFloat(px) / 2 - width
                let y = CGFloat(py) / 2
                box = (min(box.minX, x), max(box.maxX, x), min(box.minY, y), max(box.maxY, y))
            }
        }
        XCTAssertGreaterThanOrEqual(box.minX, -30, "\(box)")
        XCTAssertLessThanOrEqual(box.minX, -26, "\(box)")
        XCTAssertLessThanOrEqual(box.maxX, -9.5, "\(box)")
        XCTAssertGreaterThanOrEqual(box.minY, 2, "\(box)")
        XCTAssertLessThanOrEqual(box.minY, 8, "\(box)")
        XCTAssertLessThanOrEqual(box.maxY, 22, "\(box)")
        for y in stride(from: CGFloat(4.5), through: 19.5, by: 1) {
            let card = try color(width - 70, y)
            for x in stride(from: width - 49.5, through: width - 34.5, by: 1) {
                XCTAssertLessThan(try distance(color(x, y), card), 0.02, "no refresh icon unhovered at \(x), \(y)")
            }
        }
        // Beside the flag the label ends at W − 42: a long title gives way
        // before the flag's rect instead of running under it.
        let narrow: CGFloat = 150
        let english = MiniWindowLogicLanguageScope(.english)
        let long = try Self.render(GeekIStatIPSection(title: "Public IP Addresses", addresses: [], flag: "🇦🇺"),
                                   width: narrow)
        english.restore()
        for y in stride(from: CGFloat(6.5), through: 17.5, by: 1) {
            let card = try XCTUnwrap(long.colorAt(x: Int((narrow - 70) * 2), y: Int(25 * 2))?.usingColorSpace(.sRGB))
            for x in stride(from: narrow - 40.5, through: narrow - 31.5, by: 1) {
                let pixel = try XCTUnwrap(long.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
                XCTAssertLessThan(distance(pixel, card), 0.02, "the label stops before the flag at \(x), \(y)")
            }
        }
        try Self.export(name: "l2-network-ip-sections") { mode in
            try Self.render(
                VStack(spacing: GeekPanelLayout.detailSpacing) {
                    GeekIStatIPSection(title: L10n.text("公共 IP 地址", "Public IP Addresses"),
                                       addresses: GeekPublicNetworkAddressSection.addresses(
                                           MiniWindowDemoData.publicNetworkAddressSnapshot),
                                       flag: "🇦🇺", refresh: {})
                    GeekIStatIPSection(title: GeekIStatInterfaceModel.addressesTitle, addresses: Self.demoAddresses)
                }, width: width, mode: mode)
        }
    }

    /// The refresh icon looks the public addresses up again at once, within
    /// the same demand as any lookup: never without a page asking for them,
    /// while paused or hidden.
    func testTheRefreshIconLooksUpAgainOnlyOnDemand() async {
        let probe = IPSectionLookupProbe()
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let state = MenuBarAuxiliaryMonitorState(collectionClock: { at },
            statusWiFiProvider: { .init(sampledAt: $0, state: .unknown) },
            batteryAvailabilityProvider: { .absent }, diskCounterProvider: { nil },
            storageVolumeProvider: { .empty }, batterySnapshotProvider: { (nil, nil) },
            publicNetworkAddressProvider: { await probe.snapshot() },
            publicNetworkConsentProvider: { true }, networkProcessProvider: { nil }, processorTelemetryProvider: { nil },
            powerTelemetryProvider: { .unsupported(at: at) }, powerTelemetryPause: {}, powerHistoryURL: nil,
            chargeLimitReader: { nil })
        state.requestPublicNetworkAddressRefresh()
        await Self.settle()
        var count = await probe.callCount
        XCTAssertEqual(count, 0, "no page asks for them")

        let consumer = UUID()
        let demand = MenuBarAuxiliaryMonitorDemand(needsProcessorTelemetry: false, needsDiskIOSampling: false,
            needsNetworkInterface: false, needsPublicNetworkAddress: true, needsNetworkProcesses: false,
            needsStorageCapacity: false, needsBattery: false)
        state.registerConsumer(consumer, demand: demand, paused: false)
        defer { state.setPaused(true); state.unregisterConsumer(consumer) }
        count = await Self.waitForCount(probe, atLeast: 1)
        XCTAssertEqual(count, 1, "the page's first lookup")

        state.requestPublicNetworkAddressRefresh()
        count = await Self.waitForCount(probe, atLeast: 2)
        XCTAssertEqual(count, 2, "the icon looks up again although the result is cached")

        state.setPaused(true)
        state.requestPublicNetworkAddressRefresh()
        await Self.settle()
        count = await probe.callCount
        XCTAssertEqual(count, 2, "paused")
        state.setPaused(false)
        await Self.settle()
        let resumed = await probe.callCount
        state.setPresentationVisible(false)
        state.requestPublicNetworkAddressRefresh()
        await Self.settle()
        count = await probe.callCount
        XCTAssertEqual(count, resumed, "hidden")
    }

    /// The network page's sections: the public one from the lookup with the
    /// refresh, the local one from every connected interface's list, the
    /// demo never looking anything up.
    func testTheNetworkPageUsesIStatsSections() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let network = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"), encoding: .utf8)
        let state = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift"), encoding: .utf8)
        XCTAssertTrue(network.contains("refresh: requestPublicNetworkAddressRefresh"))
        XCTAssertTrue(network.contains("NetworkAddressListing.menuAddresses("))
        XCTAssertTrue(network.contains(
            "connection: geekConnectionSnapshot.ipConfiguration.listedAddresses\n"
                + "                ?? [geekPhysicalIPv4Address, geekPhysicalIPv6Address].compactMap { $0 },"))
        XCTAssertTrue(network.contains(
            "tunnels: [networkTopologySnapshot?.activeVPNTunnel].compactMap { $0 }\n"
                + "                + (networkTopologySnapshot?.additionalVPNTunnels ?? [])"))
        XCTAssertTrue(network.contains(
            "status: isReading ? L10n.text(\"正在读取…\", \"Reading…\") : L10n.text(\"没有 IP 地址\", \"No IP Addresses\")"))
        XCTAssertTrue(network.contains(
            "status: isLoading ? L10n.text(\"正在读取…\", \"Reading…\") : L10n.text(\"暂不可用\", \"Unavailable\")"))
        XCTAssertTrue(network.contains("isLoading: !store.isMenuBarRefreshPaused && isRefreshingPublicNetworkAddress,"))
        let native = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Services/NativeNetworkInterfaceService.swift"), encoding: .utf8)
        XCTAssertTrue(native.contains("listedAddresses: addresses.listed\n"))
        XCTAssertTrue(network.contains("addresses = connection.ipConfiguration.listedAddresses"))
        XCTAssertTrue(network.contains("addresses = tunnel.listedAddresses"))
        let refresh = try XCTUnwrap(network.components(separatedBy: "func requestPublicNetworkAddressRefresh() {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(refresh.contains("if MiniWindowDemoData.isEnabled { return }"))
        let stateRefresh = try XCTUnwrap(state.components(separatedBy: "func requestPublicNetworkAddressRefresh() {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(stateRefresh.contains("guard !isPaused, isPresentationVisible, !consumers.isEmpty else { return }"))
        XCTAssertTrue(stateRefresh.contains("refreshPublicNetworkAddressIfReady(force: true)"))
        XCTAssertEqual(MiniWindowDemoData.networkInterfaceSnapshot.listedAddresses, Self.demoAddresses)

        // A wrapped row highlights at its own height; the state of a section
        // without an address is its help and VoiceOver value.
        let sections = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekIStatInterfaceSections.swift"), encoding: .utf8)
        let row = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatSelectableRow<Content: View>: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(row.contains(".frame(minHeight: GeekIStatSectionGeometry.rowHeight)"))
        XCTAssertTrue(row.contains("cornerRadius: GeekVisualTokens.highlightRadius(rowHeight: proxy.size.height)"))
        XCTAssertTrue(sections.contains(".modifier(GeekIStatIPSectionStatus(status: addresses.isEmpty ? status : nil))"))
        let status = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatIPSectionStatus: ViewModifier {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(status.contains(".help(status)"))
        XCTAssertTrue(status.contains(".accessibilityValue(Text(status))"))
        // Hidden, the refresh icon takes no click; beside a flag it is 34
        // from the trailing edge.
        XCTAssertTrue(sections.contains(".opacity(isHovered ? 1 : 0)\n                        .allowsHitTesting(isHovered)"))
        XCTAssertTrue(sections.contains("? GeekIStatIPSectionGeometry.refreshTrailing\n"
            + "                            : GeekIStatIPSectionGeometry.refreshTrailingBesideFlag)"))
        XCTAssertEqual(GeekVisualTokens.highlightRadius(rowHeight: 15), 6)
        XCTAssertEqual(GeekVisualTokens.highlightRadius(rowHeight: 30), GeekVisualTokens.cardRadius)
    }

    // MARK: - Helpers

    private static let demoAddresses = ["192.0.2.35", "2001:db8::35"]
    /// 241 pt in the rows' font.
    private static let longAddress = "2001:db8:85a3:8d3:1319:8a2e:370:7348"
    /// The longest IPv6 form, 264 pt.
    private static let longestAddress = "2001:0db8:85a3:08d3:1319:8a2e:0370:7348"

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private static func waitForCount(_ probe: IPSectionLookupProbe, atLeast expected: Int) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var count = await probe.callCount
        while count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            count = await probe.callCount
        }
        return count
    }

    /// A section on the panel at `width`; a level-three page (`insetPage`)
    /// on its column's width less the page's 8 pt insets.
    private static func content<Content: View>(_ content: Content, width: CGFloat, mode: MiniWindowVisualMode,
                                               insetPage: Bool) -> some View {
        let inset = insetPage ? GeekPanelLayout.contentPadding : 0
        return content
            .frame(width: width - 2 * inset, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.miniWindowPageProvidesInset, insetPage)
            .environment(\.geekIStatCopyAction, GeekIStatCopyAction { _ in
                XCTFail("A render must never copy")
            })
            .padding(inset)
            .metricPanelShell()
            .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
    }

    private static func render<Content: View>(_ view: Content, width: CGFloat, mode: MiniWindowVisualMode = .black,
                                              insetPage: Bool = false) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content(view, width: width, mode: mode, insetPage: insetPage))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// The view's own height, without the panel's shell: 0 for no view.
    private static func renderedHeight<Content: View>(_ view: Content, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.displayScale, 2))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return 0 }
        return CGFloat(image.height) / 2
    }

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

/// Counts the public lookups and answers with documentation addresses.
private actor IPSectionLookupProbe {
    private(set) var callCount = 0

    func snapshot() -> PublicNetworkAddressSnapshot {
        callCount += 1
        return PublicNetworkAddressSnapshot(
            generatedAt: Date(),
            ipv4Address: "203.0.113.35",
            ipv6Address: "2001:db8:1::35",
            ipv4CountryCode: "AU",
            ipv6CountryCode: "AU"
        )
    }
}
#endif
