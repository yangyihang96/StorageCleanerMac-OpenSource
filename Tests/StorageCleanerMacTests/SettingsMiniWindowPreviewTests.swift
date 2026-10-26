#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SettingsMiniWindowPreviewTests: XCTestCase {
    private let viewport = CGSize(width: 352, height: 720)
    // Frozen NOTES revision 2. Independent of the production size resolver.
    // D118 (old values: 106, 122, 78, 81, 108, 64): iStat's level-one cards.
    private let cardHeights: [GeekDashboardModule: CGFloat] = [
        .processorGraphics: 120, .coreMetrics: 112, .disk: 42,
        .network: 100, .sensors: 88, .power: 40
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
                // D118 (old values: 6 pt between cards, 304 pt wide): 7 and
                // 301. The empty panel stays 8 + 48 + 8.
                let expectedHeight: CGFloat = modules.isEmpty ? 64
                    : modules.reduce(16) { $0 + (cardHeights[$1] ?? 0) } + CGFloat(modules.count - 1) * 7
                XCTAssertEqual(panel.width, 301, accuracy: 0.5, "mask=\(mask), dark=\(dark)")
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
                    // D118 (old value: 288): 301 − 2 × 8.
                    XCTAssertEqual(card.width, 285, accuracy: 0.5)
                    XCTAssertEqual(card.height, try XCTUnwrap(cardHeights[module]), accuracy: 0.5)
                    XCTAssertEqual(card.minX - panel.minX, 8, accuracy: 0.5)
                    XCTAssertEqual(card.minY, nextY, accuracy: 0.5)
                    XCTAssertEqual(card.minY - panel.minY, liveCard.minY - livePanel.minY, accuracy: 0.5)
                    XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(card))
                    nextY = card.maxY + 7 // D118 (old value: 6)
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
            // D118 (old values: 304 wide, 659 = 16 + 8 + 24 + 6 + 605): the
            // caption, status row and gaps above iStat's 301 × 553 panel. The
            // test keeps its name for the baseline comparison.
            XCTAssertEqual(component.width, 301, accuracy: 0.5)
            XCTAssertEqual(component.height, 607, accuracy: 0.5)
            XCTAssertEqual(panel.size, CGSize(width: 301, height: 553))
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
        // D118 (old value: 304 × 535 = 605 − 64 − 6): 553 − 40 − 7. The test
        // keeps its name for the baseline comparison.
        XCTAssertEqual(try XCTUnwrap(frames["settings.preview.panel"]).size, CGSize(width: 301, height: 506))
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
        // D118 (old value: 605 − 78 − 6): the 42 pt disk card and its 7 pt gap.
        XCTAssertEqual(try XCTUnwrap(hidden["settings.preview.panel"]).height, 553 - 42 - 7, accuracy: 0.5)
    }

    func testAppearanceSurfaceChartAndStatusPreferencesReachSameMountedPanelImmediately() async throws {
        // D135: the panel draws iStat's theme for the app's appearance. The
        // former mini-window appearance, dropdown surface, chart color and
        // background preferences stay stored but no longer apply, so each
        // step sets the preference that replaced it; the identity checks
        // are unchanged.
        let light = try XCTUnwrap(IStatMenuTheme.theme(id: "light"))
        let transparentLight = try XCTUnwrap(IStatMenuTheme.theme(id: "vibrant-light"))
        let indigo = try XCTUnwrap(IStatMenuTheme.theme(id: IStatMenuTheme.defaultID))
        for dark in [false, true] {
            let defaults = TestPreferenceDomain.make(for: self)
            let readback = PreviewRenderRecorder()
            let host = preferenceHost(defaults, readback: readback, dark: dark)
            defer { host.close() }
            let initial = try await render(host, readback: readback) { _ in true }
            // D135 (old: `miniWindowAppearanceKey` light): the app's light appearance.
            defaults.set(AppAppearance.light.rawValue, forKey: L10n.appearanceDefaultsKey)
            let day = try await render(host, readback: readback) { $0.visualMode == .graphite }
            XCTAssertEqual(initial.identity, day.identity)
            // D135 (old: the white dropdown surface): iStat's Light theme for
            // the light appearance, dark text on its own surface.
            defaults.set(light.id, forKey: IStatMenuThemePreferences.lightThemeKey)
            let white = try await render(host, readback: readback) { $0.controlScheme == .light }
            XCTAssertEqual(white.shell, light.surface.color)
            XCTAssertEqual(white.identity, initial.identity)
            // D135 (old: the custom chart color #13579B, which the GPU and
            // sensor rings took): the chart color is not read; 匹配系统外观
            // with transparency on picks the transparent light theme, and the
            // rings keep their metric colors, the accent's primary.
            defaults.set(PanelColorTheme.custom.rawValue, forKey: PanelAppearancePreferences.colorThemeKey)
            defaults.set("#13579B", forKey: PanelAppearancePreferences.chartColorKey)
            defaults.set(IStatMenuTheme.systemID, forKey: IStatMenuThemePreferences.lightThemeKey)
            let chart = try await render(host, readback: readback) { $0.shell == transparentLight.surface.color }
            XCTAssertEqual(chart.controlScheme, .light)
            XCTAssertNil(chart.chartAccent)
            XCTAssertEqual(chart.gpuTint, chart.metrics[PanelMetricColorRole.gpu.rawValue])
            XCTAssertEqual(chart.sensorTint, chart.metrics[PanelMetricColorRole.sensorGraph.rawValue])
            XCTAssertEqual(chart.identity, initial.identity)
            // D135 (old: the custom background #975321): no background tint;
            // turning transparency off picks the opaque Light theme.
            defaults.set(PanelSurfacePreset.original.rawValue, forKey: PanelPalettePreferences.surfaceThemeKey)
            defaults.set("#975321", forKey: PanelAppearancePreferences.backgroundColorKey)
            defaults.set(false, forKey: IStatMenuThemePreferences.vibrancyKey)
            let background = try await render(host, readback: readback) { $0.shell == light.surface.color }
            XCTAssertNil(background.backgroundTint)
            XCTAssertEqual(background.identity, initial.identity)
            defaults.set(PanelStatusColorPreset.custom.rawValue, forKey: PanelPalettePreferences.statusThemeKey)
            defaults.set("#A1476B", forKey: PanelPalettePreferences.statusCustomDayKey)
            defaults.set("#59B38D", forKey: PanelPalettePreferences.statusCustomNightKey)
            let expectedStatus = Color(nsColor: try XCTUnwrap(PanelStatusColorPreset.custom.ink(dark: dark,
                customDayHex: "#A1476B", customNightHex: "#59B38D")))
            let status = try await render(host, readback: readback) { $0.statusInk == expectedStatus }
            XCTAssertEqual(status.identity, initial.identity)
            XCTAssertFalse(status.permitsHardwareControl)
            // Following the app must observe app.appearance too, without a new
            // host. D135 (old: also `miniWindowAppearanceKey` set to system):
            // the dark appearance draws the dark theme, indigo by default.
            defaults.set(AppAppearance.light.rawValue, forKey: L10n.appearanceDefaultsKey)
            _ = try await render(host, readback: readback) { $0.visualMode == .graphite }
            defaults.set(AppAppearance.dark.rawValue, forKey: L10n.appearanceDefaultsKey)
            let followNight = try await render(host, readback: readback) { $0.visualMode == .black }
            XCTAssertEqual(followNight.shell, indigo.surface.color)
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
        // D135 (old: `miniWindowAppearanceKey` light and the ivory surface,
        // which no longer apply): the app's light appearance and iStat's
        // Light theme for it.
        let light = try XCTUnwrap(IStatMenuTheme.theme(id: "light"))
        fixture.defaults.set(AppAppearance.light.rawValue, forKey: L10n.appearanceDefaultsKey)
        fixture.defaults.set(light.id, forKey: IStatMenuThemePreferences.lightThemeKey)
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
        // D135: iStat's Light theme draws dark text (light controls).
        XCTAssertEqual(restored.controlScheme, .light)
        XCTAssertEqual(restored.shell, light.surface.color)
        XCTAssertEqual(restored.shell, saved.shell)
        XCTAssertEqual(restored.metrics, saved.metrics)
        XCTAssertEqual(restored.metrics[PanelMetricColorRole.cpuUser.rawValue],
                       PanelAppearancePreferences.color(from: "#2468AC"))
        XCTAssertEqual(restored.statusInk, saved.statusInk)
        XCTAssertEqual(restored.chartAccent, saved.chartAccent)
        XCTAssertEqual(restored.backgroundTint, saved.backgroundTint)
        XCTAssertNotEqual(restored.identity, saved.identity, "This check uses a reopened host, unlike immediate-change tests")
    }

    func testD73FanHeaderIsPresentAndPreviewHasNoHardwareEffects() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let host = previewHost(.defaultValue, defaults: defaults)
        defer { host.close() }
        // D118 (old: the D73 title-row entry beside `overview.sensor.header`):
        // the sensors card has no title row; the fan control is the card's
        // menu in its top-left 24 pt corner.
        let frames = try await host.frames(required: ["overview.sensor.entry", "overview.sensor.card", "settings.preview.panel"], size: viewport)
        let entry = try XCTUnwrap(frames["overview.sensor.entry"])
        let card = try XCTUnwrap(frames["overview.sensor.card"])
        XCTAssertGreaterThan(entry.width, 0)
        XCTAssertEqual(entry.minX, card.minX, accuracy: 0.5)
        XCTAssertEqual(entry.minY, card.minY, accuracy: 0.5)
        XCTAssertEqual(entry.width, GeekIStatCardMenuButton.side, accuracy: 0.5)
        XCTAssertEqual(entry.height, GeekIStatCardMenuButton.side, accuracy: 0.5)
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
