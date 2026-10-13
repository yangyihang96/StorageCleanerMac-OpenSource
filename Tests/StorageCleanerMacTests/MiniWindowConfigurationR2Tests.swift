import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MiniWindowConfigurationR2Tests: XCTestCase {
    func testDraftCancelApplyAndRestartPreserveCommittedSettings() throws {
        let name = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: name))
        defer { TestPreferenceDomain.cleanup(suiteName: name) }
        let owner = GeekDashboardConfigurationStore(defaults: defaults, fanControlProvider: { TestOperationFactory(for: self).fanControl(defaults: defaults) })
        var draft = GeekDashboardDraft(owner.configuration)
        draft.value.setModule(.network, isVisible: false)
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(owner.configuration.modules.first { $0.module == .network }!.isVisible)
        draft.cancel()
        XCTAssertFalse(draft.isDirty)
        draft.value.moveModule(.network, toGap: 0)
        draft.value.setModule(.disk, isVisible: false)
        try owner.apply(draft.value)
        XCTAssertEqual(owner.revision, 1)
        XCTAssertEqual(GeekDashboardConfigurationStore(defaults: defaults, fanControlProvider: { TestOperationFactory(for: self).fanControl(defaults: defaults) }).configuration, owner.configuration)
    }
    func testEveryInsertionGapAndBothEdgesPreserveEachModuleExactlyOnce() {
        let original = GeekDashboardConfiguration.defaultValue
        for module in original.modules.map(\.module) {
            for gap in 0...original.modules.count {
                var value = original
                let source = value.modules.firstIndex { $0.module == module }!
                value.moveModule(module, toGap: gap)
                XCTAssertEqual(value.modules[gap > source ? gap - 1 : gap].module, module)
                XCTAssertEqual(Set(value.modules.map(\.module)).count, original.modules.count)
            }
        }
    }
    func testAllHiddenIsHonoredByBothModesAndStopsOverviewSupplementalDemand() {
        var value = GeekDashboardConfiguration.defaultValue
        for module in value.modules.map(\.module) { value.setModule(module, isVisible: false) }
        for profile in [GeekPanelContentProfile.full, .reduced] {
            XCTAssertTrue(profile.overviewModules(configuredModules: value.modules).isEmpty)
        }
        for density in [PanelDensity.geek, .complex] {
            let demand = density.auxiliaryDemand(for: .overview, geekConfiguration: value)
            XCTAssertFalse(demand.needsProcessorTelemetry)
            XCTAssertFalse(demand.needsDiskIOSampling)
            XCTAssertFalse(demand.needsNetworkInterface)
        }
    }
    func testMalformedSavedConfigurationRecoversDefaults() throws {
        let name = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: name))
        defer { TestPreferenceDomain.cleanup(suiteName: name) }
        defaults.set(Data("broken".utf8), forKey: GeekDashboardConfiguration.defaultsKey)
        XCTAssertEqual(GeekDashboardConfigurationStore(defaults: defaults, fanControlProvider: { TestOperationFactory(for: self).fanControl(defaults: defaults) }).configuration, .defaultValue)
    }
}
