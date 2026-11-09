#if DEBUG
import AgentGatewayCore
import AgentShared
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Renders every page of the real settings window for review. The window is
/// never ordered in, so nothing appears on any display, and the preferences
/// come from a test domain. Runs only when SCM_SETTINGS_RENDER_DIR names the
/// folder for the PNGs.
@MainActor
final class SettingsPagesRenderReviewTests: XCTestCase {
    private struct Variant {
        let name: String
        let language: AppLanguage
        let dark: Bool
        let size: CGSize
    }

    private static let variants = [
        Variant(name: "zh-light", language: .zhHans, dark: false, size: CGSize(width: 1180, height: 732)),
        Variant(name: "zh-dark", language: .zhHans, dark: true, size: CGSize(width: 1180, height: 732)),
        Variant(name: "en-light", language: .english, dark: false, size: CGSize(width: 1180, height: 732)),
        Variant(name: "zh-light-tall", language: .zhHans, dark: false, size: CGSize(width: 1180, height: 1900)),
        Variant(name: "zh-light-narrow", language: .zhHans, dark: false, size: CGSize(width: 700, height: 560)),
    ]

    func testRenderEveryPage() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCM_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set SCM_SETTINGS_RENDER_DIR to render the settings pages.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for variant in Self.variants {
            let scope = CalibrationLanguageScope(variant.language)
            defer { scope.restore() }
            for category in SettingsCategory.allCases where category != .miniWindow {
                try await renderPage(category, name: category.rawValue, variant: variant, in: directory)
            }
            for page in SettingsMenuBarPage.allCases {
                try await renderPage(.miniWindow, name: "menuBar-\(page.rawValue)", variant: variant, in: directory) {
                    $0.set(page.rawValue, forKey: SettingsMenuBarPage.defaultsKey)
                }
            }
            // The menu bar's icon page while the combined icon is the display.
            try await renderPage(.miniWindow, name: "menuBar-icon-combined", variant: variant, in: directory) {
                $0.set(SettingsMenuBarPage.icon.rawValue, forKey: SettingsMenuBarPage.defaultsKey)
                $0.set(MenuBarStatusDisplayMode.combinedStatus.rawValue, forKey: MenuBarStatusDisplayMode.defaultsKey)
            }
        }
    }

    /// The default render stops at "not registered"; the fan page's other states
    /// need a helper. Fan ranges still come from this Mac's SMC, read as the real
    /// page reads them, and every helper request throws.
    func testRenderFanPageStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCM_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set SCM_SETTINGS_RENDER_DIR to render the settings pages.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let states: [(name: String, status: FanControlHelperStatus, mode: GeekFanControlMode)] = [
            ("automatic", .enabled, .systemAutomatic),
            ("curve", .enabled, .customCurve),
            ("manual", .enabled, .manual),
            ("maximum", .enabled, .maximum),
            ("approval", .requiresApproval, .systemAutomatic),
            ("migration", .needsMigration, .systemAutomatic),
            ("unavailable", .unavailable, .systemAutomatic),
        ]
        for height: CGFloat in [732, 1100] {
            let variant = Variant(name: "zh-light-\(Int(height))", language: .zhHans, dark: false,
                                  size: CGSize(width: 1180, height: height))
            for state in states {
                try await renderPage(.systemControl, name: "fan-\(state.name)", variant: variant, in: directory,
                                     fanControl: { defaults in
                    let coordinator = FanControlCoordinator(
                        defaults: defaults, helperStatusOverride: state.status,
                        isHelperReachable: state.status == .enabled,
                        requestSender: { _ in throw CancellationError() },
                        legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                        serviceStatusProvider: { .enabled })
                    coordinator.selectedMode = state.mode
                    return coordinator
                })
            }
        }
    }

    /// The AI assistant page's states, at the default window and at the smallest
    /// one, where the nine tabs are tightest. A listening gateway needs a signed
    /// bridge, so that one status is set directly; the clients and the log go
    /// through the real registry and the real log, in a temporary folder.
    func testRenderAgentPageStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCM_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set SCM_SETTINGS_RENDER_DIR to render the settings pages.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let variants = Self.variants.filter { ["zh-light", "zh-dark", "en-light", "zh-light-tall"].contains($0.name) } + [
            Variant(name: "zh-light-min", language: .zhHans, dark: false, size: CGSize(width: 560, height: 732)),
            Variant(name: "en-light-min", language: .english, dark: false, size: CGSize(width: 560, height: 732)),
        ]
        for variant in variants {
            let scope = CalibrationLanguageScope(variant.language)
            defer { scope.restore() }
            // First time: the explanation, before anything else.
            try await renderAgentState("intro", variant: variant, in: directory, introSeen: false) { _, _ in }
            try await renderAgentState("off", variant: variant, in: directory) { _, _ in }
            try await renderAgentState("on", variant: variant, in: directory) { interface, defaults in
                defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
                interface.showStatusForReview(.listening)
            }
            try await renderAgentState("failed", variant: variant, in: directory) { interface, _ in
                interface.setEnabled(true)
                await interface.waitForStatusUpdate()
            }
            try await renderAgentState("clients", variant: variant, in: directory) { interface, defaults in
                defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
                interface.showStatusForReview(.listening)
                try await self.addReviewClients(to: interface)
            }
            try await renderAgentState("log", variant: variant, in: directory, showsAccessLog: true) { interface, defaults in
                defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
                interface.showStatusForReview(.listening)
                try await self.addReviewClients(to: interface)
            }
        }
    }

    private func renderAgentState(_ name: String, variant: Variant, in directory: URL, introSeen: Bool = true, showsAccessLog: Bool = false,
                                  prepare: @MainActor (AgentInterface, UserDefaults) async throws -> Void) async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(SettingsCategory.aiAssistant.rawValue, forKey: "settings.selected-category.v1")
        defaults.set(introSeen, forKey: AgentSettingsPage.introSeenKey)
        let interface = try reviewInterface(defaults: defaults, startsGateway: true)
        try await prepare(interface, defaults)
        interface.refreshForSettings()
        await interface.waitForAccessRead()
        let url = directory.appendingPathComponent("\(variant.name)-ai-\(name).png")
        if showsAccessLog {
            // The real window opens with the log folded; only this row differs.
            try await render(SettingsLightfieldPane(category: .aiAssistant) { SettingsColumn { AgentSettingsPage(interface: interface, showsAccessLog: true) } }
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, variant.dark ? .dark : .light),
                variant: variant, to: url)
        } else {
            let coordinator = TestOperationFactory(for: self).fanControl(defaults: defaults)
            defer { coordinator.disconnectForTermination() }
            try await render(SettingsView(fanControl: coordinator, agentInterface: interface)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, variant.dark ? .dark : .light),
                variant: variant, to: url)
        }
    }

    private func addReviewClients(to interface: AgentInterface) async throws {
        let registry = try XCTUnwrap(interface.registry)
        let waiting = [
            AgentClientIdentity(kind: .signed, identifier: "com.openai.codex", team: "2DC432GLL2", cdhash: nil,
                                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", displayName: "Codex"),
            AgentClientIdentity(kind: .unsigned, identifier: nil, team: nil, cdhash: nil,
                                executablePath: "~/Developer/tools/very-long-folder-name/agent-runner", displayName: "agent-runner"),
        ]
        for client in waiting {
            _ = registry.notePending(client, at: Date())
            interface.clientAskedForApproval(client)
        }
        let now = Date()
        let decided: [(AgentClientIdentity, AgentClientDecision)] = [
            (AgentClientIdentity(kind: .signed, identifier: "com.anthropic.claudefordesktop", team: "Q6L2SF6YDW", cdhash: nil,
                                 executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", displayName: "Claude"), .readOnly),
            (AgentClientIdentity(kind: .adHoc, identifier: "a.out", team: nil, cdhash: "ab12", executablePath: "~/bin/helper", displayName: "helper"), .propose),
            (AgentClientIdentity(kind: .signed, identifier: "com.fixture.denied", team: "DENIED1234", cdhash: nil,
                                 executablePath: "/Applications/Denied.app/Contents/MacOS/Denied", displayName: "Denied"), .denied),
        ]
        for (client, decision) in decided { interface.decide(client, decision) }
        registry.markUsed(decided[0].0, at: now.addingTimeInterval(-300))
        let gateway = try XCTUnwrap(interface.gateway)
        let log = await gateway.accessLog
        let dataDirectory = URL(fileURLWithPath: log.fileURL.path).deletingLastPathComponent().deletingLastPathComponent()
        _ = try AgentSocketDirectory.prepare(dataDirectory: dataDirectory)
        log.append(.init(time: now.addingTimeInterval(-600), client: "agent-runner", clientKey: "k", tool: "get_overview", level: .read, outcome: .refused, reason: .approvalRequired))
        log.append(.init(time: now.addingTimeInterval(-300), client: "Claude", clientKey: "k", tool: "get_live_status", level: .read, outcome: .allowed))
        log.append(.init(time: now.addingTimeInterval(-200), client: "Claude", clientKey: "k", tool: "start_scan", level: .scan, outcome: .refused, reason: .notYetAvailable))
        log.append(.init(time: now.addingTimeInterval(-100), client: "Claude", clientKey: "k", tool: "get_health", level: .read, outcome: .failed))
    }

    /// In a temporary folder and a test domain; never the real gateway.
    private func reviewInterface(defaults: UserDefaults, startsGateway: Bool = false) throws -> AgentInterface {
        // `sun_path` holds 103 bytes; `TestFileSystem`'s roots are too long for it.
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("sca-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        let interface = AgentInterface(defaults: defaults, dataDirectory: data, applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"),
                                       launchBlocked: !startsGateway, announceWaitingClient: { _ in })
        if startsGateway { interface.start(source: AgentInterfaceLifecycleTests.EmptySource()) }
        return interface
    }

    private func renderPage(_ category: SettingsCategory, name: String, variant: Variant, in directory: URL,
                            prepare: (UserDefaults) -> Void = { _ in },
                            fanControl: ((UserDefaults) -> FanControlCoordinator)? = nil) async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(category.rawValue, forKey: "settings.selected-category.v1")
        prepare(defaults)
        // By default a coordinator that refuses every write and reports any it was asked for.
        let coordinator = fanControl?(defaults) ?? TestOperationFactory(for: self).fanControl(defaults: defaults)
        defer { coordinator.disconnectForTermination() }
        let interface = try reviewInterface(defaults: defaults)
        try await render(SettingsView(fanControl: coordinator, agentInterface: interface)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, variant.dark ? .dark : .light),
            variant: variant, to: directory.appendingPathComponent("\(variant.name)-\(name).png"))
    }

    private func render<Content: View>(_ root: Content, variant: Variant, to url: URL) async throws {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: variant.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<4 {
            hosting.frame = NSRect(origin: .zero, size: variant.size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
