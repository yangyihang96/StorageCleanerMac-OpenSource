import XCTest
@testable import StorageCleanerMac

final class VPNControlServiceTests: XCTestCase {
    func testResolverOnlyMakesVerifiedPPPServiceDirectlyControllable() {
        let resolver = VPNControlCapabilityResolver(
            serviceIDVerifier: FixedServiceIDVerifier(verifiedIDs: ["ppp-service"]),
            providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: true)
        )

        XCTAssertEqual(
            resolver.capability(for: tunnel(protocolKind: .ppp, serviceID: "ppp-service")),
            .systemConfigurationConnection(serviceID: "ppp-service")
        )
        XCTAssertEqual(
            resolver.capability(for: tunnel(protocolKind: .ikev2, serviceID: "ppp-service")),
            .openSystemSettingsOnly
        )
        XCTAssertEqual(
            resolver.capability(for: tunnel(protocolKind: .packetTunnel, serviceID: "ppp-service")),
            .openSystemSettingsOnly
        )
    }

    func testResolverUsesProviderAppOnlyWhenURLIsReliable() {
        let providerURL = URL(fileURLWithPath: "/Applications/Surfshark.app")
        let reliableResolver = VPNControlCapabilityResolver(
            serviceIDVerifier: FixedServiceIDVerifier(),
            providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: true)
        )
        let unreliableResolver = VPNControlCapabilityResolver(
            serviceIDVerifier: FixedServiceIDVerifier(),
            providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: false)
        )
        let thirdPartyTunnel = tunnel(
            protocolKind: .ikev2,
            serviceID: "surfshark-service",
            providerURL: providerURL
        )

        XCTAssertEqual(
            reliableResolver.capability(for: thirdPartyTunnel),
            .openProviderApplication(providerURL)
        )
        XCTAssertEqual(
            unreliableResolver.capability(for: thirdPartyTunnel),
            .openSystemSettingsOnly
        )
    }

    func testPreflightRejectsDisconnectedPPPBeforeControl() async {
        let service = VPNControlService(
            resolver: VPNControlCapabilityResolver(
                serviceIDVerifier: FixedServiceIDVerifier(verifiedIDs: ["ppp-service"]),
                providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: false)
            ),
            connectionController: RecordingPPPController(),
            applicationOpener: RecordingApplicationOpener()
        )

        let preflight = await service.preflight(
            for: tunnel(protocolKind: .ppp, serviceID: "ppp-service", status: .disconnected)
        )

        XCTAssertEqual(preflight.capability, .systemConfigurationConnection(serviceID: "ppp-service"))
        XCTAssertEqual(preflight.failure, .connectionNotActive(.disconnected))
        XCTAssertFalse(preflight.canExecute)
    }

    func testRepeatedDirectStopReturnsAlreadyInProgressWithoutSecondRequest() async {
        let controller = BlockingPPPController()
        let service = VPNControlService(
            resolver: VPNControlCapabilityResolver(
                serviceIDVerifier: FixedServiceIDVerifier(verifiedIDs: ["ppp-service"]),
                providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: false)
            ),
            connectionController: controller,
            applicationOpener: RecordingApplicationOpener()
        )
        let activeTunnel = tunnel(protocolKind: .ppp, serviceID: "ppp-service")

        let firstRequest = Task { await service.perform(for: activeTunnel) }
        await controller.waitUntilStarted()

        let duplicateResult = await service.perform(for: activeTunnel)
        let requestsWhileBlocked = await controller.callCount()
        XCTAssertEqual(duplicateResult, .alreadyInProgress)
        XCTAssertEqual(requestsWhileBlocked, 1)

        await controller.release()
        let firstResult = await firstRequest.value
        XCTAssertEqual(firstResult, .stopRequestSubmitted)
    }

    func testProviderOpenFailureFallsBackToSystemSettingsWithoutClaimingDisconnect() async {
        let providerURL = URL(fileURLWithPath: "/Applications/Surfshark.app")
        let opener = RecordingApplicationOpener(providerResult: false, systemSettingsResult: true)
        let service = VPNControlService(
            resolver: VPNControlCapabilityResolver(
                serviceIDVerifier: FixedServiceIDVerifier(),
                providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: true)
            ),
            connectionController: RecordingPPPController(),
            applicationOpener: opener
        )

        let result = await service.perform(
            for: tunnel(
                protocolKind: .ikev2,
                serviceID: "surfshark-service",
                providerURL: providerURL
            )
        )

        let openerEvents = await opener.events()
        XCTAssertEqual(result, .openedSystemSettings)
        XCTAssertEqual(openerEvents, ["provider", "settings"])
    }

    func testDirectStopFailureRemainsExplicit() async {
        let controller = RecordingPPPController(error: .stopRejected)
        let service = VPNControlService(
            resolver: VPNControlCapabilityResolver(
                serviceIDVerifier: FixedServiceIDVerifier(verifiedIDs: ["ppp-service"]),
                providerApplicationURLVerifier: FixedProviderURLVerifier(isReliable: false)
            ),
            connectionController: controller,
            applicationOpener: RecordingApplicationOpener()
        )

        let result = await service.perform(
            for: tunnel(protocolKind: .ppp, serviceID: "ppp-service")
        )
        let requests = await controller.callCount()
        XCTAssertEqual(result, .unavailable(.stopRequestRejected))
        XCTAssertEqual(requests, 1)
    }

    private func tunnel(
        protocolKind: VPNProtocolKind,
        serviceID: String?,
        status: VPNStatus = .connected,
        providerURL: URL? = nil
    ) -> VPNTunnelSnapshot {
        VPNTunnelSnapshot(
            stableID: serviceID.map { "service:\($0)" },
            serviceID: serviceID,
            displayName: "Test VPN",
            providerName: nil,
            providerBundleIdentifier: nil,
            providerApplicationURL: providerURL,
            protocolKind: protocolKind,
            bsdName: protocolKind == .ppp ? "ppp0" : "ipsec0",
            status: status,
            tunnelIPv4: [],
            tunnelIPv6: [],
            scopedDNSServers: [],
            gatewayOrRemoteAddress: nil,
            isDefaultRoute: true,
            isSplitTunnel: false
        )
    }
}

private struct FixedServiceIDVerifier: VPNServiceIDVerifying {
    var verifiedIDs: Set<String> = []

    func isVerifiedPPPServiceID(_ serviceID: String) -> Bool {
        verifiedIDs.contains(serviceID)
    }
}

private struct FixedProviderURLVerifier: VPNProviderApplicationURLVerifying {
    let isReliable: Bool

    func isReliableProviderApplicationURL(_ url: URL) -> Bool {
        isReliable
    }
}

private actor RecordingPPPController: VPNSystemConnectionControlling {
    private var requests = 0
    private let error: VPNSystemConnectionControlError?

    init(error: VPNSystemConnectionControlError? = nil) {
        self.error = error
    }

    func stopPPPConnection(serviceID: String) async throws {
        requests += 1
        if let error { throw error }
    }

    func callCount() -> Int { requests }
}

private actor BlockingPPPController: VPNSystemConnectionControlling {
    private var requests = 0
    private var didStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func stopPPPConnection(serviceID: String) async throws {
        requests += 1
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func callCount() -> Int { requests }
}

private actor RecordingApplicationOpener: VPNControlApplicationOpening {
    private let providerResult: Bool
    private let systemSettingsResult: Bool
    private var recordedEvents: [String] = []

    init(providerResult: Bool = true, systemSettingsResult: Bool = true) {
        self.providerResult = providerResult
        self.systemSettingsResult = systemSettingsResult
    }

    func openProviderApplication(at url: URL) async -> Bool {
        recordedEvents.append("provider")
        return providerResult
    }

    func openSystemSettings() async -> Bool {
        recordedEvents.append("settings")
        return systemSettingsResult
    }

    func events() -> [String] { recordedEvents }
}
