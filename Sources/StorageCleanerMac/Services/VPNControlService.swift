import AppKit
import Foundation
import SystemConfiguration

/// The only actions this app may offer for a discovered VPN.  A capability is
/// deliberately separate from `VPNTunnelSnapshot`: discovery must remain
/// read-only and never imply that a third-party tunnel is safe to control.
enum VPNControlCapability: Equatable, Sendable {
    /// Reserved for a VPN configuration owned by this application. No such
    /// configuration is currently created by StorageCleanerMac.
    case ownedNEVPNConnection
    /// The sole direct-stop path: an independently verified PPP service.
    case systemConfigurationConnection(serviceID: String)
    /// A verified provider application can be opened, but not controlled.
    case openProviderApplication(URL)
    /// The tunnel has a system service identity, but must be managed by macOS.
    case openSystemSettingsOnly
    /// A tunnel is visible but has no trustworthy management route.
    case readOnly
    /// A malformed or invalid tunnel cannot be acted upon.
    case unsupported

    var canRequestDirectStop: Bool {
        if case .systemConfigurationConnection = self { return true }
        return false
    }
}

enum VPNControlFailure: Equatable, Sendable {
    case connectionNotActive(VPNStatus)
    case ownedConnectionUnavailable
    case providerApplicationUnavailable
    case systemSettingsUnavailable
    case readOnly
    case unsupported
    case systemConnectionUnavailable
    case stopRequestRejected
}

struct VPNControlPreflight: Equatable, Sendable {
    let capability: VPNControlCapability
    let failure: VPNControlFailure?

    var canExecute: Bool { failure == nil }
}

enum VPNControlResult: Equatable, Sendable {
    /// SystemConfiguration accepted an asynchronous PPP stop request. This is
    /// intentionally not reported as a completed disconnect.
    case stopRequestSubmitted
    case openedProviderApplication
    case openedSystemSettings
    case alreadyInProgress
    case unavailable(VPNControlFailure)
}

enum VPNSystemConnectionControlError: Error, Equatable, Sendable {
    case unavailable
    case notActive(VPNStatus)
    case stopRejected
}

protocol VPNServiceIDVerifying: Sendable {
    func isVerifiedPPPServiceID(_ serviceID: String) -> Bool
}

protocol VPNProviderApplicationURLVerifying: Sendable {
    func isReliableProviderApplicationURL(_ url: URL) -> Bool
}

/// Re-checks that a service ID is still present in the public SystemConfiguration
/// database and is a PPP service. A snapshot's service ID alone is not enough.
struct SystemConfigurationVPNServiceIDVerifier: VPNServiceIDVerifying {
    func isVerifiedPPPServiceID(_ serviceID: String) -> Bool {
        let normalizedID = serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let preferences = SCPreferencesCreate(
                  nil,
                  "StorageCleanerMac.VPNControl" as CFString,
                  nil
              ),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return false
        }

        return services.contains { service in
            guard let currentID = SCNetworkServiceGetServiceID(service) as String?,
                  currentID == normalizedID,
                  let interface = SCNetworkServiceGetInterface(service),
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String? else {
                return false
            }
            return interfaceType.caseInsensitiveCompare("PPP") == .orderedSame
        }
    }
}

struct FileSystemVPNProviderApplicationURLVerifier: VPNProviderApplicationURLVerifying {
    func isReliableProviderApplicationURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

struct VPNControlCapabilityResolver: Sendable {
    private let serviceIDVerifier: any VPNServiceIDVerifying
    private let providerApplicationURLVerifier: any VPNProviderApplicationURLVerifying

    init(
        serviceIDVerifier: any VPNServiceIDVerifying = SystemConfigurationVPNServiceIDVerifier(),
        providerApplicationURLVerifier: any VPNProviderApplicationURLVerifying = FileSystemVPNProviderApplicationURLVerifier()
    ) {
        self.serviceIDVerifier = serviceIDVerifier
        self.providerApplicationURLVerifier = providerApplicationURLVerifier
    }

    func capability(for tunnel: VPNTunnelSnapshot) -> VPNControlCapability {
        guard tunnel.status != .invalid else { return .unsupported }

        if tunnel.protocolKind == .ppp,
           let serviceID = normalizedServiceID(tunnel.serviceID),
           serviceIDVerifier.isVerifiedPPPServiceID(serviceID) {
            return .systemConfigurationConnection(serviceID: serviceID)
        }

        if let providerURL = tunnel.providerApplicationURL,
           providerApplicationURLVerifier.isReliableProviderApplicationURL(providerURL) {
            return .openProviderApplication(providerURL)
        }

        if normalizedServiceID(tunnel.serviceID) != nil {
            return .openSystemSettingsOnly
        }

        return .readOnly
    }

    func preflight(for tunnel: VPNTunnelSnapshot) -> VPNControlPreflight {
        let capability = capability(for: tunnel)
        switch capability {
        case .systemConfigurationConnection:
            switch tunnel.status {
            case .connected, .connecting, .reconnecting:
                return VPNControlPreflight(capability: capability, failure: nil)
            default:
                return VPNControlPreflight(
                    capability: capability,
                    failure: .connectionNotActive(tunnel.status)
                )
            }
        case .openProviderApplication, .openSystemSettingsOnly:
            return VPNControlPreflight(capability: capability, failure: nil)
        case .ownedNEVPNConnection:
            return VPNControlPreflight(
                capability: capability,
                failure: .ownedConnectionUnavailable
            )
        case .readOnly:
            return VPNControlPreflight(capability: capability, failure: .readOnly)
        case .unsupported:
            return VPNControlPreflight(capability: capability, failure: .unsupported)
        }
    }

    private func normalizedServiceID(_ serviceID: String?) -> String? {
        guard let serviceID else { return nil }
        let trimmed = serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

protocol VPNSystemConnectionControlling: Sendable {
    func stopPPPConnection(serviceID: String) async throws
}

/// Public SystemConfiguration only. This intentionally uses an arbitrated
/// (non-forced) stop and is never selected for IKEv2 or Packet Tunnel VPNs.
struct SystemConfigurationPPPConnectionController: VPNSystemConnectionControlling {
    func stopPPPConnection(serviceID: String) async throws {
        // Re-check immediately before creating the connection. This makes a
        // stale snapshot or a changed service configuration fail closed.
        guard SystemConfigurationVPNServiceIDVerifier().isVerifiedPPPServiceID(serviceID),
              let connection = SCNetworkConnectionCreateWithServiceID(
            nil,
            serviceID as CFString,
            nil,
            nil
        ) else {
            throw VPNSystemConnectionControlError.unavailable
        }

        let status = vpnStatus(for: SCNetworkConnectionGetStatus(connection))
        guard status == .connected || status == .connecting || status == .reconnecting else {
            throw VPNSystemConnectionControlError.notActive(status)
        }

        guard SCNetworkConnectionStop(connection, false) else {
            throw VPNSystemConnectionControlError.stopRejected
        }
    }

    private func vpnStatus(for status: SCNetworkConnectionStatus) -> VPNStatus {
        switch status {
        case .invalid: .invalid
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        default: .unknown
        }
    }
}

protocol VPNControlApplicationOpening: Sendable {
    /// `true` only confirms Launch Services accepted the request.
    func openProviderApplication(at url: URL) async -> Bool
    /// Opens the System Settings application, without a private pane URL.
    func openSystemSettings() async -> Bool
}

struct NSWorkspaceVPNControlApplicationOpener: VPNControlApplicationOpening {
    func openProviderApplication(at url: URL) async -> Bool {
        await Self.openApplication(at: url)
    }

    func openSystemSettings() async -> Bool {
        guard let url = await Self.systemSettingsApplicationURL() else { return false }
        return await Self.openApplication(at: url)
    }

    @MainActor
    private static func systemSettingsApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
    }

    @MainActor
    private static func openApplication(at url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}

/// Serializes user requests for a single tunnel. It deliberately owns no VPN
/// state and does not update UI; callers must refresh the real topology after a
/// stop request has been accepted.
actor VPNControlService {
    private let resolver: VPNControlCapabilityResolver
    private let connectionController: any VPNSystemConnectionControlling
    private let applicationOpener: any VPNControlApplicationOpening
    private var inFlightTunnelIDs = Set<String>()

    init(
        resolver: VPNControlCapabilityResolver = VPNControlCapabilityResolver(),
        connectionController: any VPNSystemConnectionControlling = SystemConfigurationPPPConnectionController(),
        applicationOpener: any VPNControlApplicationOpening = NSWorkspaceVPNControlApplicationOpener()
    ) {
        self.resolver = resolver
        self.connectionController = connectionController
        self.applicationOpener = applicationOpener
    }

    func preflight(for tunnel: VPNTunnelSnapshot) -> VPNControlPreflight {
        resolver.preflight(for: tunnel)
    }

    func perform(for tunnel: VPNTunnelSnapshot) async -> VPNControlResult {
        let tunnelID = tunnel.stableID ?? "runtime:\(tunnel.bsdName)"
        guard inFlightTunnelIDs.insert(tunnelID).inserted else {
            return .alreadyInProgress
        }
        defer { inFlightTunnelIDs.remove(tunnelID) }

        let preflight = resolver.preflight(for: tunnel)
        guard let failure = preflight.failure else {
            switch preflight.capability {
            case let .systemConfigurationConnection(serviceID):
                do {
                    try await connectionController.stopPPPConnection(serviceID: serviceID)
                    return .stopRequestSubmitted
                } catch let error as VPNSystemConnectionControlError {
                    return .unavailable(failure(for: error))
                } catch {
                    return .unavailable(.stopRequestRejected)
                }
            case let .openProviderApplication(url):
                if await applicationOpener.openProviderApplication(at: url) {
                    return .openedProviderApplication
                }
                if await applicationOpener.openSystemSettings() {
                    return .openedSystemSettings
                }
                return .unavailable(.providerApplicationUnavailable)
            case .openSystemSettingsOnly:
                return await applicationOpener.openSystemSettings()
                    ? .openedSystemSettings
                    : .unavailable(.systemSettingsUnavailable)
            case .ownedNEVPNConnection, .readOnly, .unsupported:
                // These are handled by preflight; keep this exhaustive guard
                // against a future capability changing between checks.
                return .unavailable(.unsupported)
            }
        }
        return .unavailable(failure)
    }

    private func failure(for error: VPNSystemConnectionControlError) -> VPNControlFailure {
        switch error {
        case .unavailable:
            .systemConnectionUnavailable
        case .notActive(let status):
            .connectionNotActive(status)
        case .stopRejected:
            .stopRequestRejected
        }
    }
}
