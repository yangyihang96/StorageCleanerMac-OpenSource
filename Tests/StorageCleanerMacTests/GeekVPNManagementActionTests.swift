#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// UI plan U1 085: in the mini window's VPN detail, "断开连接" is a
/// destructive, full-width button with a larger click area (concept 085).
/// Only the presentation is checked: the injected control action fails the
/// test if anything calls it, so nothing is ever disconnected.
@MainActor
final class GeekVPNManagementActionTests: XCTestCase {
    func testOnlyTheDisconnectRequestIsDestructive() {
        let disconnect = GeekVPNHoverDetail.actionPresentation(
            for: VPNControlPreflight(capability: .systemConfigurationConnection(serviceID: "ppp"), failure: nil)
        )
        XCTAssertEqual(disconnect?.title, L10n.text("断开连接", "Disconnect"))
        XCTAssertEqual(disconnect?.isDestructive, true)

        let provider = GeekVPNHoverDetail.actionPresentation(
            for: VPNControlPreflight(
                capability: .openProviderApplication(URL(fileURLWithPath: "/Applications/WireGuard.app")),
                failure: nil
            )
        )
        XCTAssertEqual(provider?.title, L10n.text("打开 VPN 应用", "Open VPN App"))
        XCTAssertEqual(provider?.isDestructive, false)

        let settings = GeekVPNHoverDetail.actionPresentation(
            for: VPNControlPreflight(capability: .openSystemSettingsOnly, failure: nil)
        )
        XCTAssertEqual(settings?.title, L10n.text("打开系统设置", "Open System Settings"))
        XCTAssertEqual(settings?.isDestructive, false)

        for capability in [VPNControlCapability.readOnly, .unsupported, .ownedNEVPNConnection] {
            XCTAssertNil(GeekVPNHoverDetail.actionPresentation(
                for: VPNControlPreflight(capability: capability, failure: nil)
            ))
        }
        XCTAssertNil(GeekVPNHoverDetail.actionPresentation(
            for: VPNControlPreflight(
                capability: .systemConfigurationConnection(serviceID: "ppp"),
                failure: .connectionNotActive(.disconnected)
            )
        ))
    }

    func testDisconnectFillsTheManagementCardWithALargerClickArea() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = VPNActionLanguageScope(language)
            defer { languageScope.restore() }
            for scenario in [
                MiniWindowDemoData.MenuBarSnapshotScenario.networkVPNPPP,
                .networkVPNThirdParty,
                .networkVPNSystem,
            ] {
                let tunnel = try XCTUnwrap(MiniWindowDemoData.vpnTunnel(for: scenario))
                let size = GeekVPNHoverDetail.preferredSize(for: tunnel)
                let recorder = VPNActionFrameRecorder()
                let root = GeekVPNHoverDetail(
                    tunnel: tunnel,
                    refresh: {},
                    capabilityResolver: MiniWindowDemoData.vpnCapabilityResolver,
                    controlAction: { _ in
                        XCTFail("Layout inspection must never request a VPN action")
                        return .unavailable(.unsupported)
                    }
                )
                .layoutProbe("vpn.panel")
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
                let host = VPNActionHost(root: root, size: size)
                defer { host.close() }
                let frames = try await host.frames(
                    from: recorder,
                    required: ["vpn.panel", "vpn.management.card", "vpn.management.action",
                               "vpn.management.description"]
                )
                let tag = "\(scenario.rawValue) \(language)"
                let panel = try XCTUnwrap(frames["vpn.panel"])
                let card = try XCTUnwrap(frames["vpn.management.card"])
                let action = try XCTUnwrap(frames["vpn.management.action"])
                let description = try XCTUnwrap(frames["vpn.management.description"])
                // Review P2-5: one-line and two-line descriptions both leave the
                // same space above the text as below the button.
                XCTAssertEqual(description.minY - card.minY, card.maxY - action.maxY, accuracy: 1,
                               "Balanced card: \(tag), description height \(description.height)")
                XCTAssertGreaterThanOrEqual(action.minY, description.maxY + 4, tag)
                // Full card width (inside the card's 8 pt insets) and 30 pt tall,
                // where the old small bordered text button was about 20 pt.
                XCTAssertEqual(action.width, card.width - 2 * MiniWindowStyleTokens.cardHorizontalInset,
                               accuracy: 1, tag)
                XCTAssertGreaterThanOrEqual(action.height, GeekVPNManagementActionButton.height - 0.5, tag)
                XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(action), tag)
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(card), "Card fits the panel: \(tag)")
            }
        }
    }

    func testDisconnectUsesTheDestructiveStyleAndStillAsksFirst() throws {
        let network = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"),
            encoding: .utf8
        )
        let button = try XCTUnwrap(network.components(separatedBy: "struct GeekVPNManagementActionButton: View").last)
        XCTAssertTrue(button.contains("role: isDestructive ? .destructive : nil"))
        XCTAssertTrue(button.contains("AppDesignTokens.Palette.destructive"))
        XCTAssertTrue(network.contains("GeekVPNManagementActionButton("))
        // The old small, blue bordered button is gone.
        XCTAssertFalse(network.contains("""
                        Button(actionTitle) {
                            requestAction()
                        }
                        .buttonStyle(.bordered)
        """))
        // A disconnect still opens the confirmation first.
        XCTAssertTrue(network.contains("isConfirmingDisconnect = true"))
        XCTAssertTrue(network.contains("L10n.text(\"断开 VPN？\", \"Disconnect VPN?\")"))
    }
}

/// Override only this test process's volatile argument domain.
@MainActor
private final class VPNActionLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

@MainActor
private final class VPNActionFrameRecorder {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class VPNActionHost<Root: View> {
    private let host: NSHostingView<Root>
    private let window: NSWindow

    init(root: Root, size: CGSize) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func frames(from recorder: VPNActionFrameRecorder, required: Set<String>) async throws -> [String: CGRect] {
        var lastFrames: [String: CGRect]?
        var stable = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if required.isSubset(of: Set(recorder.frames.keys)) {
                let current = recorder.frames.filter { required.contains($0.key) }
                if current == lastFrames { stable += 1 } else { stable = 0 }
                lastFrames = current
                if stable >= 2 { return current }
            }
        }
        throw NSError(domain: "GeekVPNManagementActionTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native layout frames did not stabilize"])
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
