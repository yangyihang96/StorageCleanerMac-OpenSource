import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

final class ModuleThemeTests: XCTestCase {
    func testDeveloperPageKeepsGoldenWarmSurfaceWithoutChangingItsNavigationGroup() throws {
        let theme = ReviewFilter.devCaches.moduleTheme
        let background = try XCTUnwrap(NSColor(theme.darkGradientStart).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(background.redComponent, background.blueComponent)
        XCTAssertEqual(theme.featureGroup, .cleanup)
        XCTAssertNotEqual(colorKey(theme.darkGradientStart), colorKey(ReviewFilter.green.moduleTheme.darkGradientStart))
        XCTAssertTrue(theme.isImmersive)
    }

    func testRoutesUseCategoryLevelThemes() {
        XCTAssertEqual(ReviewFilter.overview.featureGroup, .smartScan)
        XCTAssertEqual(ReviewFilter.green.featureGroup, .cleanup)
        XCTAssertEqual(ReviewFilter.devCaches.featureGroup, .cleanup)
        XCTAssertEqual(ReviewFilter.healthHub.featureGroup, .protection)
        XCTAssertEqual(ReviewFilter.privacy.featureGroup, .protection)
        XCTAssertEqual(ReviewFilter.performance.featureGroup, .performance)
        XCTAssertEqual(ReviewFilter.startup.featureGroup, .performance)
        XCTAssertEqual(ReviewFilter.memory.featureGroup, .performance)
        XCTAssertEqual(ReviewFilter.energy.featureGroup, .performance)
        XCTAssertEqual(ReviewFilter.uninstall.featureGroup, .applications)
        XCTAssertEqual(ReviewFilter.updater.featureGroup, .applications)
        XCTAssertEqual(ReviewFilter.largeFiles.featureGroup, .files)
        XCTAssertEqual(ReviewFilter.migration.featureGroup, .files)
        XCTAssertEqual(ReviewFilter.duplicates.featureGroup, .files)
        XCTAssertEqual(ReviewFilter.utilityHub.featureGroup, .settings)
    }

    func testRoutesInOneCategoryShareOneThemeIdentity() {
        let performance = [
            ReviewFilter.performance,
            .startup,
            .memory,
            .energy
        ]
        let applications = [ReviewFilter.uninstall, .updater]
        let protection = [ReviewFilter.healthHub, .privacy]
        let neutralDashboards = [ReviewFilter.utilityHub]

        XCTAssertEqual(Set(performance.map(\.moduleTheme.identifier)), [FeatureGroup.performance.rawValue])
        XCTAssertEqual(Set(applications.map(\.moduleTheme.identifier)), [FeatureGroup.applications.rawValue])
        XCTAssertEqual(Set(protection.map(\.moduleTheme.identifier)), [FeatureGroup.protection.rawValue])
        XCTAssertEqual(Set(neutralDashboards.map(\.moduleTheme.identifier)), [FeatureGroup.settings.rawValue])
    }

    func testEveryRouteResolvesThroughAnExplicitFeatureGroup() {
        for route in ReviewFilter.allCases {
            XCTAssertEqual(route.moduleTheme.identifier, route.featureGroup.rawValue, route.rawValue)
        }
        XCTAssertEqual(ReviewFilter.sidebarItems(in: .files), [.largeFiles, .migration, .duplicates])
    }

    func testEveryFeatureGroupOwnsOneCompleteThemeIdentity() {
        for group in FeatureGroup.allCases {
            let theme = ModuleThemeCatalog.theme(for: group)
            XCTAssertEqual(theme.featureGroup, group)
            XCTAssertEqual(theme.identifier, group.rawValue)
            XCTAssertEqual(theme.isImmersive, group != .settings)
        }

        let brandedGroups = FeatureGroup.allCases.filter { $0 != .settings }
        let accents = brandedGroups.map { colorKey(ModuleThemeCatalog.theme(for: $0).accent) }
        let lightStarts = brandedGroups.map {
            colorKey(ModuleThemeCatalog.theme(for: $0).startColor(for: .light))
        }
        XCTAssertEqual(Set(accents).count, brandedGroups.count)
        XCTAssertEqual(Set(lightStarts).count, 2)
        XCTAssertFalse(ModuleTheme.neutral.isImmersive)
        XCTAssertEqual(colorKey(ModuleThemeCatalog.theme(for: .settings).accent), colorKey(.accentColor))
    }

    private func colorKey(
        _ color: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("Could not resolve theme colors", file: file, line: line)
            return "unresolved"
        }
        return String(
            format: "%.3f-%.3f-%.3f-%.3f",
            resolved.redComponent,
            resolved.greenComponent,
            resolved.blueComponent,
            resolved.alphaComponent
        )
    }
}
