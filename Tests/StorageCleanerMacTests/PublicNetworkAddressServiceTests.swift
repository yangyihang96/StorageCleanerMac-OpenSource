import Darwin
import XCTest
@testable import StorageCleanerMac

final class PublicNetworkAddressServiceTests: XCTestCase {
    @MainActor
    func testDefaultsNotificationFromBackgroundDoesNotAssertMainActorIsolation() async {
        let state = MenuBarAuxiliaryMonitorState(publicNetworkConsentProvider: { false }, powerHistoryURL: nil)
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await Task.yield()
        withExtendedLifetime(state) { }
    }

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
            publicNetworkConsentProvider: { true },
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

    @MainActor
    func testSuccessUsesFifteenMinuteCacheAndFailureRetriesAfterSixtySeconds() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func shouldRefresh(_ seconds: TimeInterval, hasAddress: Bool) -> Bool {
            MenuBarAuxiliaryMonitorState.shouldRefreshPublicNetworkAddress(force: false,
                networkSignature: "same", previousNetworkSignature: "same", lastAttemptAt: at,
                hasPublicAddress: hasAddress, now: at.addingTimeInterval(seconds))
        }
        XCTAssertFalse(shouldRefresh(899.99, hasAddress: true))
        XCTAssertTrue(shouldRefresh(900, hasAddress: true))
        XCTAssertFalse(shouldRefresh(59.99, hasAddress: false))
        XCTAssertTrue(shouldRefresh(60, hasAddress: false))
        XCTAssertTrue(MenuBarAuxiliaryMonitorState.shouldRefreshPublicNetworkAddress(force: false,
            networkSignature: "new", previousNetworkSignature: "old", lastAttemptAt: at,
            hasPublicAddress: true, now: at))
    }

    @MainActor
    func testDefaultEnabledResidentTicksRequestOnlyForVisibleNetworkPanelAndKeepCacheOnReopen() async {
        let fixture = TestPreferenceDomain.make(file: #filePath)
        let suite = fixture.suiteName
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let provider = PublicAddressProviderProbe()
        let context = MenuBarSamplingContext()
        func configure(visible: Bool) {
            context.configure(statusMode: .cpu, statusVisible: true, panelVisible: visible,
                customFanControlActive: false, paused: false)
        }
        configure(visible: false)
        let state = MenuBarAuxiliaryMonitorState(collectionClock: { at },
            statusWiFiProvider: { .init(sampledAt: $0, state: .unknown) },
            batteryAvailabilityProvider: { .absent }, diskCounterProvider: { nil },
            storageVolumeProvider: { .empty }, batterySnapshotProvider: { (nil, nil) },
            publicNetworkAddressProvider: { await provider.snapshot() },
            publicNetworkConsentProvider: {
                PublicNetworkConsent.allowsAddress(in: TestPreferenceDomain.open(suiteName: suite)!)
            }, networkProcessProvider: { nil }, processorTelemetryProvider: { nil },
            powerTelemetryProvider: { .unsupported(at: at) }, powerTelemetryPause: {}, powerHistoryURL: nil,
            chargeLimitReader: { nil })
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        let consumer = UUID()
        let demand = MenuBarAuxiliaryMonitorDemand(needsProcessorTelemetry: false, needsDiskIOSampling: false,
            needsNetworkInterface: false, needsPublicNetworkAddress: true, needsNetworkProcesses: false,
            needsStorageCapacity: false, needsBattery: false)
        state.registerConsumer(consumer, demand: demand, paused: false)
        defer { state.setPaused(true); state.unregisterConsumer(consumer) }
        state.refreshResidentSamples()
        await waitUntil { !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive
            && !state.isPowerTelemetryRefreshActive && !state.isNetworkProcessRefreshActive }
        var count = await provider.callCount
        XCTAssertEqual(count, 0, "Default enabled must not turn resident hidden ticks into public requests")

        configure(visible: true)
        state.setPresentationVisible(true)
        await waitUntil { state.publicNetworkAddressSnapshot != nil }
        count = await provider.callCount
        XCTAssertEqual(count, 1)
        state.setPresentationVisible(false)
        configure(visible: false)
        state.refreshResidentSamples()
        await waitUntil { !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive
            && !state.isPowerTelemetryRefreshActive && !state.isNetworkProcessRefreshActive }
        configure(visible: true)
        state.setPresentationVisible(true)
        for _ in 0..<4 { await Task.yield() }
        count = await provider.callCount
        XCTAssertEqual(count, 1, "Reopening uses the same fifteen-minute cache")
        state.unregisterConsumer(consumer)
        state.refreshResidentSamples()
        for _ in 0..<4 { await Task.yield() }
        count = await provider.callCount
        XCTAssertEqual(count, 1, "A visible overview without network demand does not query")
    }

    @MainActor
    func testExplicitOptOutNeverCallsInjectedAddressProvider() async {
        let fixture = TestPreferenceDomain.make(file: #filePath)
        let suite = fixture.suiteName
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        fixture.defaults.set(false, forKey: PublicNetworkConsent.addressKey)
        let provider = PublicAddressProviderProbe()
        let state = MenuBarAuxiliaryMonitorState(batteryAvailabilityProvider: { .absent },
            diskCounterProvider: { nil }, storageVolumeProvider: { .empty },
            publicNetworkAddressProvider: { await provider.snapshot() },
            publicNetworkConsentProvider: {
                PublicNetworkConsent.allowsAddress(in: TestPreferenceDomain.open(suiteName: suite)!)
            }, powerHistoryURL: nil)
        let consumer = UUID()
        state.registerConsumer(consumer, demand: MenuBarAuxiliaryMonitorDemand(needsProcessorTelemetry: false,
            needsDiskIOSampling: false, needsNetworkInterface: false, needsPublicNetworkAddress: true,
            needsNetworkProcesses: false, needsStorageCapacity: false, needsBattery: false), paused: false)
        defer { state.setPaused(true); state.unregisterConsumer(consumer) }
        for _ in 0..<4 { state.refreshFromPrimaryMonitorUpdate(); await Task.yield() }
        let count = await provider.callCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(state.publicNetworkAddressSnapshot)
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
