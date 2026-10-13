#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SettingsMiniWindowPreviewTests: XCTestCase {
    private let viewport = CGSize(width: 352, height: 720)
    // Frozen NOTES revision 2. Independent of the production size resolver.
    private let cardHeights: [GeekDashboardModule: CGFloat] = [
        .processorGraphics: 106, .coreMetrics: 122, .disk: 78,
        .network: 81, .sensors: 108, .power: 64
    ]

    func testAll64ModuleCombinationsHaveTheSameNativeGeometryAsSharedLiveComposition() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        for dark in [false, true] {
            for mask in 0..<64 {
                var configuration = GeekDashboardConfiguration.defaultValue
                for (index, module) in GeekDashboardConfiguration.defaultModuleOrder.enumerated() {
                    configuration.setModule(module, isVisible: mask & (1 << index) != 0)
                }
                let modules = configuration.modules.filter(\.isVisible).map(\.module)
                let preview = previewHost(configuration, defaults: defaults, dark: dark)
                let live = liveCompositionHost(modules: modules, defaults: defaults, dark: dark)
                defer { preview.close(); live.close() }
                let ids = Set(modules.map(moduleProbe))
                let actual = try await preview.frames(required: ids.union(["settings.preview.panel"]), size: viewport)
                let liveFrames = try await live.frames(required: ids.union(["fixture.live.panel"]), size: viewport)
                let panel = try XCTUnwrap(actual["settings.preview.panel"])
                let livePanel = try XCTUnwrap(liveFrames["fixture.live.panel"])
                let expectedHeight: CGFloat = modules.isEmpty ? 64
                    : modules.reduce(16) { $0 + (cardHeights[$1] ?? 0) } + CGFloat(modules.count - 1) * 6
                XCTAssertEqual(panel.width, 304, accuracy: 0.5, "mask=\(mask), dark=\(dark)")
                XCTAssertEqual(panel.height, expectedHeight, accuracy: 0.5)
                XCTAssertEqual(panel.size, livePanel.size, "The live composition and Settings share natural geometry")
                if !modules.isEmpty {
                    XCTAssertEqual(panel.size, GeekPanelLayout.overviewSize(modules: modules),
                        "The real window size resolver must match the measured panel")
                }
                var nextY = panel.minY + 8
                for module in modules {
                    let card = try XCTUnwrap(actual[moduleProbe(module)])
                    let liveCard = try XCTUnwrap(liveFrames[moduleProbe(module)])
                    XCTAssertEqual(card.width, 288, accuracy: 0.5)
                    XCTAssertEqual(card.height, try XCTUnwrap(cardHeights[module]), accuracy: 0.5)
                    XCTAssertEqual(card.minX - panel.minX, 8, accuracy: 0.5)
                    XCTAssertEqual(card.minY, nextY, accuracy: 0.5)
                    XCTAssertEqual(card.minY - panel.minY, liveCard.minY - livePanel.minY, accuracy: 0.5)
                    XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(card))
                    nextY = card.maxY + 6
                }
                for module in GeekDashboardConfiguration.defaultModuleOrder where !modules.contains(module) {
                    XCTAssertNil(actual[moduleProbe(module)], "Hidden modules must leave the rendered panel")
                }
            }
        }
    }

    func testCompleteComponentHas659PointHeightAndUnscaledPanelInDayAndNight() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        for dark in [false, true] {
            let root = SettingsMiniWindowPreview(configuration: .defaultValue)
                .layoutProbe("fixture.preview.component")
                .padding(.horizontal, 24)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .defaultAppStorage(defaults)
            let host = CalibrationAppKitLayoutHost(root: root, size: viewport, dark: dark)
            defer { host.close() }
            let frames = try await host.frames(required: ["settings.preview.caption", "settings.preview.status",
                "settings.preview.panel", "fixture.preview.component"], size: viewport)
            let caption = try XCTUnwrap(frames["settings.preview.caption"])
            let status = try XCTUnwrap(frames["settings.preview.status"])
            let panel = try XCTUnwrap(frames["settings.preview.panel"])
            let component = try XCTUnwrap(frames["fixture.preview.component"])
            XCTAssertEqual(component.width, 304, accuracy: 0.5)
            XCTAssertEqual(component.height, 659, accuracy: 0.5)
            XCTAssertEqual(panel.size, CGSize(width: 304, height: 605))
            XCTAssertEqual(panel.minX, 24, accuracy: 0.5)
            XCTAssertEqual(caption.height, 16, accuracy: 0.5)
            XCTAssertEqual(status.height, 24, accuracy: 0.5)
            XCTAssertEqual(status.minY - caption.maxY, 8, accuracy: 0.5)
            XCTAssertEqual(panel.minY - status.maxY, 6, accuracy: 0.5)
        }
    }

    func testNotebookExampleRemovesOnlyBatteryAndUses535PointNaturalPanel() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let host = previewHost(.defaultValue, defaults: defaults, notebook: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["settings.preview.panel", moduleProbe(.sensors)], size: viewport)
        XCTAssertEqual(try XCTUnwrap(frames["settings.preview.panel"]).size, CGSize(width: 304, height: 535))
        XCTAssertNil(frames[moduleProbe(.power)])
        XCTAssertNotNil(frames[moduleProbe(.processorGraphics)])
    }

    func testReorderAndVisibilityChangeRenderImmediatelyInTheSameHost() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let configuration = PreviewConfigurationModel()
        let host = CalibrationAppKitLayoutHost(root: PreviewConfigurationFixture(model: configuration)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .defaultAppStorage(defaults), size: viewport, dark: true)
        defer { host.close() }
        let ids = Set(GeekDashboardConfiguration.defaultModuleOrder.map(moduleProbe))
        let before = try await host.frames(required: ids.union(["settings.preview.panel"]), size: viewport)
        configuration.value.moveModule(.power, by: -5)
        let reordered = try await host.frames(required: ids.union(["settings.preview.panel"]), size: viewport)
        XCTAssertEqual(try XCTUnwrap(reordered[moduleProbe(.power)]).minY,
                       try XCTUnwrap(reordered["settings.preview.panel"]).minY + 8, accuracy: 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(before[moduleProbe(.power)]).minY,
                             try XCTUnwrap(reordered[moduleProbe(.power)]).minY)
        XCTAssertEqual(before["settings.preview.panel"]?.size, reordered["settings.preview.panel"]?.size)
        configuration.value.setModule(.disk, isVisible: false)
        let hidden = try await host.frames(required: ids.subtracting([moduleProbe(.disk)])
            .union(["settings.preview.panel"]), size: viewport)
        XCTAssertNil(hidden[moduleProbe(.disk)])
        XCTAssertEqual(try XCTUnwrap(hidden["settings.preview.panel"]).height, 605 - 78 - 6, accuracy: 0.5)
    }

    func testAppearanceSurfaceChartAndStatusPreferencesReachSameMountedPanelImmediately() async throws {
        for dark in [false, true] {
            let defaults = TestPreferenceDomain.make(for: self)
            let readback = PreviewRenderRecorder()
            let host = preferenceHost(defaults, readback: readback, dark: dark)
            defer { host.close() }
            let initial = try await render(host, readback: readback) { _ in true }
            defaults.set(MiniWindowAppearance.light.rawValue, forKey: PanelAppearancePreferences.miniWindowAppearanceKey)
            let day = try await render(host, readback: readback) { $0.visualMode == .graphite }
            XCTAssertEqual(initial.identity, day.identity)
            defaults.set(PanelSurfacePreset.white.rawValue, forKey: PanelPalettePreferences.surfaceThemeKey)
            let white = try await render(host, readback: readback) { $0.controlScheme == .light }
            XCTAssertEqual(white.shell, PanelSurfacePreset.white.palette(for: .graphite)?.shell)
            defaults.set(PanelColorTheme.custom.rawValue, forKey: PanelAppearancePreferences.colorThemeKey)
            defaults.set("#13579B", forKey: PanelAppearancePreferences.chartColorKey)
            let chart = try await render(host, readback: readback) {
                $0.chartAccent == PanelAppearancePreferences.color(from: "#13579B")
            }
            XCTAssertEqual(chart.gpuTint, chart.chartAccent)
            XCTAssertEqual(chart.sensorTint, chart.chartAccent)
            defaults.set(PanelSurfacePreset.original.rawValue, forKey: PanelPalettePreferences.surfaceThemeKey)
            defaults.set("#975321", forKey: PanelAppearancePreferences.backgroundColorKey)
            let tint = PanelAppearancePreferences.color(from: "#975321")?
                .opacity(MiniWindowStyleTokens.panelBackgroundTintOpacity)
            let background = try await render(host, readback: readback) { $0.backgroundTint == tint }
            XCTAssertEqual(background.identity, initial.identity)
            defaults.set(PanelStatusColorPreset.custom.rawValue, forKey: PanelPalettePreferences.statusThemeKey)
            defaults.set("#A1476B", forKey: PanelPalettePreferences.statusCustomDayKey)
            defaults.set("#59B38D", forKey: PanelPalettePreferences.statusCustomNightKey)
            let expectedStatus = Color(nsColor: try XCTUnwrap(PanelStatusColorPreset.custom.ink(dark: dark,
                customDayHex: "#A1476B", customNightHex: "#59B38D")))
            let status = try await render(host, readback: readback) { $0.statusInk == expectedStatus }
            XCTAssertEqual(status.identity, initial.identity)
            XCTAssertFalse(status.permitsHardwareControl)
            // Following the app must observe app.appearance too, without a new host.
            defaults.set(MiniWindowAppearance.system.rawValue, forKey: PanelAppearancePreferences.miniWindowAppearanceKey)
            defaults.set(AppAppearance.light.rawValue, forKey: L10n.appearanceDefaultsKey)
            _ = try await render(host, readback: readback) { $0.visualMode == .graphite }
            defaults.set(AppAppearance.dark.rawValue, forKey: L10n.appearanceDefaultsKey)
            let followNight = try await render(host, readback: readback) { $0.visualMode == .black }
            XCTAssertEqual(followNight.identity, initial.identity)
        }
    }

    func testAll18MetricPreferencesUpdateTheRenderedEnvironmentWithoutReplacingPanelIdentity() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let readback = PreviewRenderRecorder()
        let host = preferenceHost(defaults, readback: readback)
        defer { host.close() }
        let initial = try await render(host, readback: readback) { _ in true }
        for (index, role) in PanelMetricColorRole.allCases.enumerated() {
            let value = String(format: "#%06X", 0x123450 + index * 13)
            defaults.set(value, forKey: role.defaultsKey)
            let expected = try XCTUnwrap(PanelAppearancePreferences.color(from: value))
            let snapshot = try await render(host, readback: readback) { $0.metrics[role.rawValue] == expected }
            XCTAssertEqual(snapshot.identity, initial.identity)
            if role == .gpu { XCTAssertEqual(snapshot.gpuTint, expected) }
            if role == .sensorGraph { XCTAssertEqual(snapshot.sensorTint, expected) }
        }
    }

    func testReopeningSameIsolatedPreferenceSuiteRetainsColorsAndAppearance() async throws {
        let fixture = TestPreferenceDomain.make()
        defer { TestPreferenceDomain.cleanup(suiteName: fixture.suiteName) }
        fixture.defaults.set(MiniWindowAppearance.light.rawValue, forKey: PanelAppearancePreferences.miniWindowAppearanceKey)
        fixture.defaults.set(PanelSurfacePreset.ivory.rawValue, forKey: PanelPalettePreferences.surfaceThemeKey)
        fixture.defaults.set("#2468AC", forKey: PanelMetricColorRole.cpuUser.defaultsKey)
        fixture.defaults.set(PanelStatusColorPreset.custom.rawValue, forKey: PanelPalettePreferences.statusThemeKey)
        fixture.defaults.set("#AD6724", forKey: PanelPalettePreferences.statusCustomDayKey)
        XCTAssertTrue(fixture.defaults.synchronize())
        let firstReadback = PreviewRenderRecorder()
        let first = preferenceHost(fixture.defaults, readback: firstReadback, dark: false)
        let saved = try await render(first, readback: firstReadback) { $0.visualMode == .graphite }
        first.close()
        let reopened = try XCTUnwrap(TestPreferenceDomain.open(suiteName: fixture.suiteName))
        let nextReadback = PreviewRenderRecorder()
        let next = preferenceHost(reopened, readback: nextReadback, dark: false)
        defer { next.close() }
        let restored = try await render(next, readback: nextReadback) { $0.visualMode == .graphite }
        XCTAssertEqual(restored.controlScheme, .light)
        XCTAssertEqual(restored.shell, saved.shell)
        XCTAssertEqual(restored.metrics, saved.metrics)
        XCTAssertEqual(restored.statusInk, saved.statusInk)
        XCTAssertEqual(restored.chartAccent, saved.chartAccent)
        XCTAssertEqual(restored.backgroundTint, saved.backgroundTint)
        XCTAssertNotEqual(restored.identity, saved.identity, "This check uses a reopened host, unlike immediate-change tests")
    }

    func testD73FanHeaderIsPresentAndPreviewHasNoHardwareEffects() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let host = previewHost(.defaultValue, defaults: defaults)
        defer { host.close() }
        let frames = try await host.frames(required: ["overview.sensor.entry", "overview.sensor.header", "settings.preview.panel"], size: viewport)
        XCTAssertGreaterThan(try XCTUnwrap(frames["overview.sensor.entry"]).width, 0)
        try await host.waitForAccessibility(labels: [L10n.text("风扇控制", "Fan Control")],
            expectedValues: [L10n.text("风扇控制", "Fan Control"): MiniWindowConfigurationPreviewCard.fanEntry.status])
        let previewSource = try source("Sources/StorageCleanerMac/Views/Settings/SettingsMiniWindowPreview.swift")
        let overviewSource = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPanel.swift")
        let cardSource = try r2SourceDeclaration("struct MiniWindowConfigurationPreviewCard: View",
            in: source("Sources/StorageCleanerMac/Views/MiniWindowConfigurationSettingsView.swift"))
        for value in [previewSource, overviewSource, cardSource] {
            for forbidden in ["PanelScene(", "ScanStore(", "FanControlCoordinator(", "ControlPaletteCoordinator(",
                              "BatteryFullChargeService(", ".shared", ".task", ".onAppear", "NSPanel("] {
                XCTAssertFalse(value.contains(forbidden), "Inert rendering cannot create effects: \(forbidden)")
            }
        }
        XCTAssertTrue(previewSource.contains(".environment(\\.controlPaletteCoordinator, nil)"))
        XCTAssertTrue(previewSource.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(previewSource.contains(".disabled("), "Render-only controls must keep their real colors")
        XCTAssertFalse(previewSource.contains("ScrollView("), "The Settings host owns scrolling")
        XCTAssertTrue(cardSource.contains("fanControlEntry: Self.fanEntry"))
    }

    private func moduleProbe(_ module: GeekDashboardModule) -> String { "geek.overview.module." + module.rawValue }

    private func previewHost(_ configuration: GeekDashboardConfiguration, defaults: UserDefaults,
                             notebook: Bool = true, dark: Bool = true) -> CalibrationAppKitLayoutHost {
        CalibrationAppKitLayoutHost(root: SettingsMiniWindowPreview(configuration: configuration, notebookExample: notebook)
            .padding(.horizontal, 24)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .defaultAppStorage(defaults), size: viewport, dark: dark)
    }

    private func liveCompositionHost(modules: [GeekDashboardModule], defaults: UserDefaults,
                                     dark: Bool) -> CalibrationAppKitLayoutHost {
        // This is the production overview composition and production cards.
        // Live sampling/action wrappers are deliberately outside this inert host.
        CalibrationAppKitLayoutHost(root: GeekOverviewPanel(modules: modules) {
            MiniWindowEmptyConfigurationView()
        } content: { module in
            MiniWindowConfigurationPreviewCard(module: module)
        }
        .metricPanelShell()
        .environment(\.controlPaletteCoordinator, nil)
        .environment(\.miniWindowPreviewDate, MiniWindowConfigurationPreviewCard.history.last?.date)
        .layoutProbe("fixture.live.panel")
        .modifier(PanelAppearanceEnvironment())
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .defaultAppStorage(defaults), size: viewport, dark: dark)
    }

    private func preferenceHost(_ defaults: UserDefaults, readback: PreviewRenderRecorder,
                                dark: Bool = true) -> CalibrationAppKitLayoutHost {
        CalibrationAppKitLayoutHost(root: SettingsMiniWindowPreview(configuration: .defaultValue)
            .onPreferenceChange(SettingsMiniWindowRenderPreferenceKey.self) { [weak readback] value in
                Task { @MainActor [weak readback] in readback?.snapshot = value }
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .defaultAppStorage(defaults), size: viewport, dark: dark)
    }

    private func render(_ host: CalibrationAppKitLayoutHost, readback: PreviewRenderRecorder,
                        matching condition: (SettingsMiniWindowRenderSnapshot) -> Bool) async throws -> SettingsMiniWindowRenderSnapshot {
        for _ in 0..<100 {
            _ = try await host.frames(required: ["settings.preview.panel"], size: viewport)
            if let snapshot = readback.snapshot, condition(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SettingsMiniWindowPreviewTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The same mounted panel did not render the changed preferences"])
    }

    private func source(_ relative: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
    }
}

@MainActor
private final class PreviewRenderRecorder {
    var snapshot: SettingsMiniWindowRenderSnapshot?
}

@MainActor
private final class PreviewConfigurationModel: ObservableObject {
    @Published var value = GeekDashboardConfiguration.defaultValue
}

private struct PreviewConfigurationFixture: View {
    @ObservedObject var model: PreviewConfigurationModel
    var body: some View { SettingsMiniWindowPreview(configuration: model.value) }
}
#endif
