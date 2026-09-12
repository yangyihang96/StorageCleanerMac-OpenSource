import Darwin
import XCTest
@testable import StorageCleanerMac

final class PublicNetworkAddressServiceTests: XCTestCase {
    func testValidationAcceptsPublicAddressesAndRejectsLocalOrMalformedValues() {
        XCTAssertEqual(
            PublicNetworkAddressService.validatedAddress(" 115.70.50.19\n", family: AF_INET),
            "115.70.50.19"
        )
        XCTAssertNil(
            PublicNetworkAddressService.validatedAddress("192.168.50.53", family: AF_INET)
        )
        XCTAssertNil(
            PublicNetworkAddressService.validatedAddress("not an address", family: AF_INET)
        )

        XCTAssertEqual(
            PublicNetworkAddressService.validatedAddress(
                "2401:d002:830b:f300:b850:ffb7:8c53:a989",
                family: AF_INET6
            ),
            "2401:d002:830b:f300:b850:ffb7:8c53:a989"
        )
        XCTAssertNil(
            PublicNetworkAddressService.validatedAddress("fe80::1", family: AF_INET6)
        )
        XCTAssertNil(
            PublicNetworkAddressService.validatedAddress("2001:db8::1", family: AF_INET6)
        )
    }

    func testServiceUsesSeparateTLSIPv4AndIPv6Endpoints() {
        XCTAssertEqual(PublicNetworkAddressService.ipv4Endpoint.absoluteString, "https://api.ipify.org")
        XCTAssertEqual(PublicNetworkAddressService.ipv6Endpoint.absoluteString, "https://api6.ipify.org")
        XCTAssertEqual(PublicNetworkAddressService.countryEndpoint.absoluteString, "https://api.country.is")
    }

    func testCountryCodeValidationAndFlagFormatting() {
        XCTAssertEqual(PublicNetworkAddressService.validatedCountryCode(" au\n"), "AU")
        XCTAssertEqual(PublicNetworkAddressService.flagEmoji(forCountryCode: "AU"), "🇦🇺")
        XCTAssertEqual(PublicNetworkAddressService.flagEmoji(forCountryCode: "us"), "🇺🇸")
        XCTAssertNil(PublicNetworkAddressService.validatedCountryCode("AUS"))
        XCTAssertNil(PublicNetworkAddressService.validatedCountryCode("A1"))
        XCTAssertNil(PublicNetworkAddressService.validatedCountryCode("ZZ"))
        XCTAssertNil(PublicNetworkAddressService.flagEmoji(forCountryCode: nil))
    }

    @MainActor
    func testAuxiliaryStateCachesSuccessfulAddressAcrossPrimaryMonitorRefreshes() async {
        let provider = PublicAddressProviderProbe()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            publicNetworkAddressProvider: {
                await provider.snapshot()
            },
            powerHistoryURL: nil
        )
        let consumer = UUID()
        state.registerConsumer(
            consumer,
            demand: MenuBarAuxiliaryMonitorDemand(
                needsProcessorTelemetry: false,
                needsDiskIOSampling: false,
                needsNetworkInterface: true,
                needsPublicNetworkAddress: true,
                needsNetworkProcesses: false
            ),
            paused: false
        )
        defer { state.unregisterConsumer(consumer) }

        await waitUntil {
            state.publicNetworkAddressSnapshot?.ipv4Address == "115.70.50.19"
        }
        let initialCallCount = await provider.callCount
        XCTAssertEqual(initialCallCount, 1)

        for _ in 0..<8 {
            state.refreshFromPrimaryMonitorUpdate()
        }
        await Task.yield()
        let refreshedCallCount = await provider.callCount
        XCTAssertEqual(refreshedCallCount, 1)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private actor PublicAddressProviderProbe {
    private(set) var callCount = 0

    func snapshot() -> PublicNetworkAddressSnapshot {
        callCount += 1
        return PublicNetworkAddressSnapshot(
            generatedAt: Date(),
            ipv4Address: "115.70.50.19",
            ipv6Address: "2401:d002:830b:f300:b850:ffb7:8c53:a989",
            ipv4CountryCode: "AU",
            ipv6CountryCode: "AU"
        )
    }
}
