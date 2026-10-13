import AppKit
import FanControlShared
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MiniWindowUser1011Tests: XCTestCase {
    func testOverviewAndEveryDetailHaveNoStoredSampleHeaderOrReservedSpace() throws {
        let panel = try source("Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let components = try source("Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        XCTAssertFalse(panel.contains("MiniWindowStoredSampleAge"))
        XCTAssertFalse(components.contains("MiniWindowStoredSampleAge"))
        XCTAssertFalse(panel.contains("GeekOverviewStoredSampleLayout"))
        XCTAssertFalse(panel.contains("geekOverviewShowsStoredSampleAge"))
        XCTAssertFalse(panel.contains("sampledAt == nil ? 0 : 24"))
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/StorageCleanerMac/Views")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && file.path.contains("/MenuBar") {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("Text(L10n.text(\"采样 · \""), file.lastPathComponent)
            XCTAssertFalse(text.contains("MiniWindowStoredSampleAge("), file.lastPathComponent)
        }
        XCTAssertTrue(panel.contains(".padding(.vertical, GeekPanelLayout.contentPadding)"))
        XCTAssertTrue(try source("Views/MenuBarPanelChrome.swift").contains("static func age("),
                      "Keep provenance formatting for help and process freshness")
    }

    func testPowerUsesSharedHoverSelectionPinAndEscapeRoute() throws {
        let panel = try source("Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(panel.contains("GeekOverviewModuleButton(destination: .power, isSelected: selectedSection == .power, preview: previewGeekSection, action: selectGeekSection)"))
        let session = try source("Support/MenuBarPanelSession.swift")
        XCTAssertEqual(session.components(separatedBy: "scrollsTallDetails: section == .power").count - 1, 2,
                       "Both level two and the reserved third level must preserve the overview")
        for section in [PanelSection.processor, .network, .sensors, .power] {
            let coordinator = GeekPanelCoordinator(pointerLocationProvider: { .zero })
            coordinator.previewModule(section)
            XCTAssertEqual(coordinator.route, .module(section))
            XCTAssertNil(coordinator.pinnedModule)
            coordinator.selectModule(section)
            XCTAssertEqual(coordinator.route, .module(section))
            XCTAssertEqual(coordinator.pinnedModule, section)
            XCTAssertTrue(coordinator.handleEscape())
            XCTAssertEqual(coordinator.route, .summary)
            XCTAssertNil(coordinator.pinnedModule)
        }
    }

    func testTallPowerDetailsScrollBesideAnUnchangedOverviewOnAShortDisplay() {
        let visible = NSRect(x: 0, y: 0, width: 1_280, height: 620)
        let overview = NSRect(x: 968, y: 16, width: 304, height: 588)
        for scale in [CGFloat(1), 2] {
            let layout = MenuBarPanelPlacement.reflowingCascade(parentFrame: overview,
                childSizes: [NSSize(width: 312, height: 900), NSSize(width: 380, height: 720)],
                visibleFrame: visible, backingScaleFactor: scale, scrollsTallDetails: true)
            XCTAssertFalse(layout.isCompact, "Tall content must not become Back/Overview navigation")
            XCTAssertEqual(layout.parentFrame, overview)
            XCTAssertEqual(layout.childFrames.count, 2)
            XCTAssertLessThanOrEqual(layout.childFrames[0].maxX, overview.minX)
            XCTAssertEqual(layout.childFrames[0].height, 604)
            for frame in layout.visibleFrames { XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame)) }
        }
        let unchangedOtherModule = MenuBarPanelPlacement.reflowingCascade(parentFrame: overview,
            childSizes: [NSSize(width: 312, height: 900), NSSize(width: 380, height: 720)], visibleFrame: visible)
        XCTAssertTrue(unchangedOtherModule.isCompact, "The opt-in must not alter other modules")
    }

    func testFractionalAndNegativeScreenOriginsKeepScrollingColumnsInsideVisibleFrame() {
        let visible = NSRect(x: -1_280.25, y: -120.25, width: 1_280, height: 620)
        let overview = NSRect(x: -312.5, y: -104, width: 304, height: 560)
        let layout = MenuBarPanelPlacement.reflowingCascade(parentFrame: overview,
            childSizes: [NSSize(width: 312, height: 900), NSSize(width: 380, height: 720)],
            visibleFrame: visible, backingScaleFactor: 2, scrollsTallDetails: true)
        XCTAssertFalse(layout.isCompact)
        for frame in layout.visibleFrames { XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame)) }
    }

    func testMissingPublicAddressPreferenceEnablesLookupWithoutWritingTheKey() {
        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertNil(defaults.object(forKey: PublicNetworkConsent.addressKey))
        XCTAssertTrue(PublicNetworkConsent.allowsAddress(in: defaults))
        XCTAssertNil(defaults.object(forKey: PublicNetworkConsent.addressKey), "Reading the default must not persist consent")
        defaults.set(false, forKey: PublicNetworkConsent.addressKey)
        XCTAssertFalse(PublicNetworkConsent.allowsAddress(in: defaults), "An explicit opt-out survives")
        defaults.set(true, forKey: PublicNetworkConsent.addressKey)
        XCTAssertTrue(PublicNetworkConsent.allowsAddress(in: defaults))
    }

    func testSettingsCardAndServiceUseOnePublicAddressDefaultAndDiscloseActualDomains() throws {
        for path in ["Views/SettingsView.swift", "Views/MenuBarAdvanced/GeekNetworkView.swift"] {
            XCTAssertTrue(try source(path).contains("= PublicNetworkConsent.defaultAllowsAddress"), path)
        }
        let settings = try source("Views/Settings/SettingsAccess.swift")
        for endpoint in [PublicNetworkAddressService.ipv4Endpoint, PublicNetworkAddressService.ipv6Endpoint,
                         PublicNetworkAddressService.countryEndpoint] {
            XCTAssertTrue(settings.contains(try XCTUnwrap(endpoint.host)))
        }
        XCTAssertTrue(settings.contains("公网 IP 可关闭，地区查询须另行同意"))
        XCTAssertTrue(try source("Services/BoundedHTTPSReader.swift").contains("allowsAddress && UserDefaults.standard.bool(forKey: countryKey)"),
                      "Default IP lookup must not silently grant country lookup")
    }

    func testNoReadingsRenderNoDashRowsAndPartialReadingsPreserveZero() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for state in [HelperPowerMetricsState.needsHelper, .needsUpdate, .sampling, .failed(.timedOut)] {
            let presentation = GeekHelperPowerMetricsPresentation(state: state, now: now)
            XCTAssertTrue(presentation.powerRows.isEmpty)
            XCTAssertTrue(presentation.frequencyRows.isEmpty)
            XCTAssertFalse(presentation.unavailableText.contains("—"))
            XCTAssertFalse(presentation.unavailableText.isEmpty)
        }
        let partial = PowermetricsSample(cpuMilliwatts: nil, gpuMilliwatts: 0, aneMilliwatts: nil,
            clusters: [.init(name: "E0", kind: .efficiency, megahertz: 0)], gpuMegahertz: nil, durationSeconds: 1)
        let presentation = GeekHelperPowerMetricsPresentation(state: .available(partial, sampledAt: now), now: now)
        XCTAssertEqual(presentation.powerRows.map(\.id), ["gpu"])
        XCTAssertEqual(presentation.powerRows.map(\.value), ["0.00 W"])
        XCTAssertEqual(presentation.frequencyRows.map(\.title), ["能效簇"])
        XCTAssertEqual(presentation.frequencyRows.map(\.value), ["0 MHz"])
    }

    func testAvailableReadingsEnterPowerAndFrequencyCardsWithProvenanceInHelp() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sample = PowermetricsSample(cpuMilliwatts: 12_400, gpuMilliwatts: 6_400, aneMilliwatts: 0,
            clusters: [.init(name: "P0", kind: .performance, megahertz: 3_600),
                       .init(name: "E0", kind: .efficiency, megahertz: 1_800)], gpuMegahertz: 340, durationSeconds: 1)
        let presentation = GeekHelperPowerMetricsPresentation(state: .available(sample, sampledAt: at), now: at.addingTimeInterval(60))
        XCTAssertEqual(presentation.powerRows.map(\.title), ["CPU", "GPU", "神经网络引擎"])
        XCTAssertEqual(presentation.frequencyRows.map(\.title), ["性能簇", "能效簇", "GPU"])
        XCTAssertTrue(presentation.powerRows.allSatisfy { $0.sampledAt == at })
        XCTAssertTrue(presentation.helpText.contains("powermetrics"))
        XCTAssertTrue(presentation.helpText.contains("60 秒前"), "Keep D74 stored samples instead of blanking old readings")
        XCTAssertFalse((presentation.powerRows + presentation.frequencyRows).contains { $0.value == "—" })
        let invalid = GeekHelperPowerMetricsPresentation(state: .available(sample, sampledAt: at.addingTimeInterval(1)), now: at)
        XCTAssertTrue(invalid.powerRows.isEmpty)
        XCTAssertTrue(invalid.frequencyRows.isEmpty)
    }

    func testHelperCardsReuseReadoutComponentAndEnableOnlyNavigatesToSettings() throws {
        let cards = try source("Views/MenuBarAdvanced/GeekHelperPowerMetricsCards.swift")
        XCTAssertTrue(cards.contains("geekSensorReadoutCard(title, rows: rows)"))
        XCTAssertTrue(cards.contains("L10n.text(\"功率\", \"POWER\")"))
        XCTAssertTrue(cards.contains("L10n.text(\"频率\", \"FREQUENCY\")"))
        XCTAssertFalse(cards.contains("Text(HelperPowerMetricsPresentation.source)"))
        XCTAssertTrue(cards.contains("settingsCategory = .accessAndSetup"))
        XCTAssertTrue(cards.contains("SystemHelperSettingsNavigation.shared.requestID = UUID()"))
        XCTAssertTrue(cards.contains("openSettings()"))
        for forbidden in ["registerHelper", "sampleIfDue", "updateConsumer", "TimelineView", "Text(\"—\")"] {
            XCTAssertFalse(cards.contains(forbidden), forbidden)
        }
    }

#if DEBUG || STORAGE_CLEANER_BETA
    func testDemoIncludesAvailableAndMissingHelperScenariosForBothSecondaryPages() {
        let scenarios: [(MiniWindowDemoData.MenuBarSnapshotScenario, MiniWindowDemoData.MenuBarSnapshotScenario, PanelSection)] = [
            (MiniWindowDemoData.MenuBarSnapshotScenario.sensorSecondary, .sensorSecondaryNoHelper, PanelSection.sensors),
            (.powerSecondary, .powerSecondaryNoHelper, .power),
        ]
        for (available, missing, section) in scenarios {
            XCTAssertEqual(available.route, .secondary(section))
            XCTAssertEqual(missing.route, .secondary(section))
            XCTAssertEqual(missing.expectedPanelCount, 2)
            let state = MiniWindowDemoData.helperPowerMetricsState(for: available)
            let presentation = GeekHelperPowerMetricsPresentation(state: state, now: MiniWindowDemoData.referenceDate)
            XCTAssertEqual(presentation.powerRows.count, 3)
            XCTAssertEqual(presentation.frequencyRows.count, 3)
            XCTAssertEqual(MiniWindowDemoData.helperPowerMetricsState(for: missing), .needsHelper)
        }
        XCTAssertEqual(MiniWindowDemoData.MenuBarSnapshotScenario.networkSecondary.route, .secondary(.network))
        XCTAssertEqual(MiniWindowDemoData.MenuBarSnapshotScenario.networkSecondaryUnavailable.route, .secondary(.network))
        XCTAssertNil(MiniWindowDemoData.publicNetworkAddressSnapshot(for: .networkSecondaryUnavailable))
        XCTAssertNotNil(MiniWindowDemoData.publicNetworkAddressSnapshot(for: .networkSecondary))
    }
#endif

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
