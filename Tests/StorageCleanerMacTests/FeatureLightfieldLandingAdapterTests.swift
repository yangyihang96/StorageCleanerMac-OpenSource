#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldLandingAdapterTests: XCTestCase {
    func testLegacyFileLandingEntryUsesLightfieldWithoutRouteEnvironmentAcrossSizes() async throws {
        let pages: [(ReviewFilter, Bool)] = [(.duplicates, false), (.duplicates, true), (.largeFiles, false), (.migration, false)]
        let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
            .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
            .init(width: 677, height: 390), .init(width: 1280, height: 390)]
        let sizes = [CGSize(width: 655, height: 468)] + windows.map {
            CGSize(width: $0.width - FeatureLightfield.sidebarWidth, height: $0.height - FeatureLightfield.titlebarHeight)
        }
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            for dark in [false, true] {
                for (module, similar) in pages {
                    var calls = 0
                    let action = L10n.text("开始扫描", "Start Scan")
                    let root = AdaptivePageViewport(resetID: module) {
                        HeroScanPage(title: similar ? L10n.text("相似照片", "Similar Photos") : module.sidebarTitle,
                            headerSystemImage: similar ? GeneratedArt.similarPhotosSystemImage : module.systemImage,
                            actionTitle: action, actionDetail: "", actionSystemImage: "play.fill", status: .neverScanned,
                            trustText: L10n.text("只读扫描", "Read-only scan"), showsAccessory: false,
                            action: { calls += 1 }) { EmptyView() }
                            .environment(\.moduleTheme, module.moduleTheme)
                            .environment(\.featureDisablesLayoutAnimations, true)
                    }
                    let host = CalibrationAppKitLayoutHost(root: root, size: sizes[0], dark: dark)
                    defer { host.close() }
                    let ids: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status",
                        "lightfield.options.scrollViewport", "lightfield.optionsEnd", "fixture.viewport"]
                    for size in sizes {
                        host.resize(to: size)
                        let frames = try await host.frames(required: ids, size: size)
                        let geometry = FeatureLightfieldGeometry(size: size, phase: .landing)
                        for (id, expected) in [("lightfield.title", geometry.title), ("lightfield.content", geometry.content),
                            ("lightfield.primary", geometry.primary), ("lightfield.status", geometry.status)] {
                            let actual = try XCTUnwrap(frames[id])
                            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
                            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
                            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
                            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
                        }
                        let button = try XCTUnwrap(frames["lightfield.primary"])
                        XCTAssertEqual(button.height, 52, accuracy: 0.5)
                        XCTAssertTrue(try XCTUnwrap(frames["fixture.viewport"]).insetBy(dx: -0.5, dy: -0.5).contains(button))
                        XCTAssertNil(frames["concept-landing.action-button"])
                        XCTAssertNotNil(frames["lightfield.optionsEnd"])
                    }
                    try await host.waitForAccessibility(labels: [action], pressLabels: [action])
                    XCTAssertTrue(try host.press(label: action))
                    XCTAssertEqual(calls, 1)
                }
            }
        }
    }

    func testLegacyLightfieldActionKeepsDisableLoadingAndOverrideSemantics() async throws {
        for (disabled, loading, allowsWhileLoading, enabled) in [
            (false, false, false, true), (true, false, false, false),
            (false, true, false, false), (false, true, true, true), (true, true, true, false)
        ] {
            var calls = 0
            let action = "Fixture action"
            let root = HeroScanPage(title: "Fixture", headerSystemImage: ReviewFilter.duplicates.systemImage,
                actionTitle: action, actionDetail: "", actionSystemImage: "play.fill", status: .neverScanned,
                isLoading: loading, isActionDisabled: disabled, allowsActionWhileLoading: allowsWhileLoading,
                action: { calls += 1 }) { EmptyView() }
                .environment(\.moduleTheme, ReviewFilter.duplicates.moduleTheme)
                .environment(\.featureDisablesLayoutAnimations, true)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 655, height: 468), dark: true)
            defer { host.close() }
            _ = try await host.frames(required: ["lightfield.primary", "fixture.viewport"], size: .init(width: 655, height: 468))
            try await host.waitForAccessibility(labels: [action], expectedEnabled: [action: enabled], pressLabels: [action])
            if enabled {
                XCTAssertTrue(try host.press(label: action))
                XCTAssertEqual(calls, 1)
            } else {
                XCTAssertEqual(calls, 0)
            }
        }
    }
}
#endif
