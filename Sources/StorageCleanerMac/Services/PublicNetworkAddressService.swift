import Darwin
import Foundation

struct PublicNetworkAddressSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let ipv4Address: String?
    let ipv6Address: String?
    let ipv4CountryCode: String?
    let ipv6CountryCode: String?

    var hasAddress: Bool {
        ipv4Address != nil || ipv6Address != nil
    }
}

/// Resolves the address visible to the public internet only when the Panel's
/// network surface asks for it. Caching and scheduling belong to the existing
/// auxiliary monitor state; this service owns no timer or persistent task.
enum PublicNetworkAddressService {
    static let ipv4Endpoint = URL(string: "https://api.ipify.org")!
    static let ipv6Endpoint = URL(string: "https://api6.ipify.org")!
    static let countryEndpoint = URL(string: "https://api.country.is")!

    static func snapshot(now: Date = Date()) async -> PublicNetworkAddressSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)

        async let ipv4 = fetchAddress(
            from: ipv4Endpoint,
            family: AF_INET,
            session: session
        )
        async let ipv6 = fetchAddress(
            from: ipv6Endpoint,
            family: AF_INET6,
            session: session
        )

        let (resolvedIPv4, resolvedIPv6) = await (ipv4, ipv6)
        async let ipv4CountryCode = fetchCountryCode(
            for: resolvedIPv4,
            session: session
        )
        async let ipv6CountryCode = fetchCountryCode(
            for: resolvedIPv6,
            session: session
        )

        return await PublicNetworkAddressSnapshot(
            generatedAt: now,
            ipv4Address: resolvedIPv4,
            ipv6Address: resolvedIPv6,
            ipv4CountryCode: ipv4CountryCode,
            ipv6CountryCode: ipv6CountryCode
        )
    }

    static func validatedCountryCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.utf8.count == 2,
              value.utf8.allSatisfy({ (65...90).contains($0) }),
              Locale.Region.isoRegions.contains(Locale.Region(value)) else {
            return nil
        }
        return value
    }

    static func flagEmoji(forCountryCode rawValue: String?) -> String? {
        guard let countryCode = validatedCountryCode(rawValue) else { return nil }
        let scalars = countryCode.unicodeScalars.compactMap {
            UnicodeScalar(127_397 + Int($0.value))
        }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    static func validatedAddress(_ rawValue: String, family: Int32) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if family == AF_INET {
            var address = in_addr()
            guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                return nil
            }
            let hostOrder = UInt32(bigEndian: address.s_addr)
            let first = UInt8((hostOrder >> 24) & 0xff)
            let second = UInt8((hostOrder >> 16) & 0xff)
            let third = UInt8((hostOrder >> 8) & 0xff)
            guard isPublicIPv4(first: first, second: second, third: third) else {
                return nil
            }
            return value
        }

        if family == AF_INET6 {
            var address = in6_addr()
            guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                return nil
            }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            guard isPublicIPv6(bytes) else { return nil }
            return value
        }

        return nil
    }

    private static func isPublicIPv4(first: UInt8, second: UInt8, third: UInt8) -> Bool {
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, 64...127 ~= second { return false }
        if first == 169, second == 254 { return false }
        if first == 172, 16...31 ~= second { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0 { return false }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return false
        }
        return true
    }

    private static func fetchAddress(
        from endpoint: URL,
        family: Int32,
        session: URLSession
    ) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count <= 128,
                  let rawValue = String(data: data, encoding: .utf8) else {
                return nil
            }
            return validatedAddress(rawValue, family: family)
        } catch {
            return nil
        }
    }

    private static func fetchCountryCode(
        for address: String?,
        session: URLSession
    ) async -> String? {
        guard let address else { return nil }
        let endpoint = countryEndpoint.appendingPathComponent(address)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count <= 4_096,
                  let payload = try? JSONDecoder().decode(CountryLookupResponse.self, from: data) else {
                return nil
            }
            return validatedCountryCode(payload.country)
        } catch {
            return nil
        }
    }

    private struct CountryLookupResponse: Decodable {
        let country: String?
    }
}
