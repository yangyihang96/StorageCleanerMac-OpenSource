import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class HealthCapabilityLayoutTests: XCTestCase {
    func testNativeCapabilityControlsScopeWithoutInventingBatteryMetrics() {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = HealthCapabilityLanguageScope(language)
            defer { languageScope.restore() }

            let absent = HealthCheckScopeCards(internalBatteryAvailability: .absent).checks
            XCTAssertEqual(absent.map(\.id), [.disk, .system])

            let present = HealthCheckScopeCards(internalBatteryAvailability: .present).checks
            XCTAssertEqual(present.map(\.id), [.disk, .battery, .system])
            let confirmedBattery = present.first { $0.id == .battery }
            XCTAssertEqual(confirmedBattery?.details, [
                L10n.text("最大容量", "Maximum capacity"),
                L10n.text("循环次数", "Cycle count"),
                L10n.text("电池状况", "Condition")
            ])

            let unknown = HealthCheckScopeCards(internalBatteryAvailability: .unknown).checks
            XCTAssertEqual(unknown.map(\.id), [.disk, .battery, .system])
            let pendingBattery = unknown.first { $0.id == .battery }
            XCTAssertEqual(pendingBattery?.systemImage, "questionmark.circle")
            XCTAssertEqual(pendingBattery?.details, [
                L10n.text("内置电池待确认", "Internal battery not confirmed")
            ])
            XCTAssertFalse((pendingBattery?.details ?? []).contains { $0.contains("0") })
        }
    }

    func testAssessmentTitleIsAccurateInBothLanguages() {
        for (language, expected) in [(AppLanguage.zhHans, "健康评估"), (.english, "Health Assessment")] {
            let languageScope = HealthCapabilityLanguageScope(language)
            defer { languageScope.restore() }
            XCTAssertEqual(HealthDashboardText.assessmentTitle, expected)
            XCTAssertEqual(ReviewFilter.healthHub.sidebarTitle,
                           L10n.text("系统健康", "System Health"))
        }
    }

#if DEBUG
    func testProductionCardsAndLabelsFitAtTheColumnBoundaryInBothAppearances() async throws {
        // These are native component layouts with injected capability values,
        // not hardware acceptance or a complete-window resize measurement.
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = HealthCapabilityLanguageScope(language)
            defer { languageScope.restore() }
            for scheme in [ColorScheme.light, .dark] {
                for pageHeight: CGFloat in [400, 800] {
                    for availability in [InternalBatteryAvailability.present, .absent, .unknown] {
                        for width: CGFloat in [230, 340, 403, 404, 435] {
                            let recorder = HealthCapabilityFrameRecorder()
                            let fixture = HealthCapabilityFixture(availability)
                            let root = HealthCapabilityFixtureView(fixture: fixture, pageHeight: pageHeight)
                                .environment(\.colorScheme, scheme)
                                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: ReviewFilter.healthHub))
                                .environment(\.locale, L10n.locale)
                                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                                    Task { @MainActor in recorder.frames = frames }
                                }
                            let host = HealthCapabilityLayoutHost(root: root, size: CGSize(width: width, height: 940))
                            defer { host.close() }
                            let checks = HealthCheckScopeCards(internalBatteryAvailability: availability).checks
                            let frames = try await host.frames(from: recorder, required: requiredFrames(checks))
                            try assertCardsInsideTheirScope(frames, checks: checks)

                            let scope = try XCTUnwrap(frames["health.scope"])
                            XCTAssertEqual(scope.width, width, accuracy: 1)
                            let cards = try checks.map { try XCTUnwrap(frames["health.scope.card.\($0.id.rawValue)"]) }
                            if availability == .absent, width >= 266 {
                                XCTAssertEqual(cards[0].width, (width - 10) / 2, accuracy: 1,
                                               "Two remaining cards must share all available width, without a battery slot")
                                XCTAssertEqual(cards[0].midY, cards[1].midY, accuracy: 1)
                                XCTAssertNil(frames["health.scope.card.battery"])
                            } else if availability != .absent, width >= 404 {
                                XCTAssertEqual(cards[0].midY, cards[2].midY, accuracy: 1,
                                               "The original three-card row must be retained where it fits")
                            } else if availability != .absent, width == 403 {
                                XCTAssertEqual(cards[0].midY, cards[1].midY, accuracy: 1)
                                XCTAssertGreaterThanOrEqual(cards[2].minY, cards[0].maxY + 9,
                                                            "The third card must wrap before it becomes unreadable")
                            }
                        }
                    }
                }
            }
        }
    }

    func testCapabilityChangesAndRepeatedNativeResizesRemoveTheBatterySlot() async throws {
        let fixture = HealthCapabilityFixture(.unknown)
        let recorder = HealthCapabilityFrameRecorder()
        let root = HealthCapabilityFixtureView(fixture: fixture, pageHeight: 800)
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let host = HealthCapabilityLayoutHost(root: root, size: CGSize(width: 435, height: 940))
        defer { host.close() }

        for availability in [InternalBatteryAvailability.unknown, .present, .absent, .unknown, .absent] {
            fixture.availability = availability
            for width: CGFloat in [435, 340, 230, 404, 435] {
                host.resize(to: CGSize(width: width, height: 940))
                let checks = HealthCheckScopeCards(internalBatteryAvailability: availability).checks
                let forbidden: Set<String> = availability == .absent ? ["health.scope.card.battery"] : []
                let frames = try await host.frames(from: recorder, required: requiredFrames(checks),
                                                   forbidden: forbidden, expectedWidth: width)
                try assertCardsInsideTheirScope(frames, checks: checks)
                if availability == .absent, width == 435 {
                    let disk = try XCTUnwrap(frames["health.scope.card.disk"])
                    let system = try XCTUnwrap(frames["health.scope.card.system"])
                    XCTAssertEqual(disk.width, 212.5, accuracy: 1)
                    XCTAssertEqual(system.maxX, try XCTUnwrap(frames["health.scope"]).maxX, accuracy: 1)
                }
            }
        }
    }

    private func requiredFrames(_ checks: [HealthCheckScopeCards.Check]) -> Set<String> {
        var result: Set<String> = ["health.scope", "health.test.viewport"]
        for check in checks {
            let id = check.id.rawValue
            result.formUnion(["health.scope.card.\(id)", "health.scope.title.\(id)"])
            if check.id == .battery && check.details == [L10n.text("内置电池待确认", "Internal battery not confirmed")] {
                result.insert("health.scope.availability.battery")
            }
        }
        return result
    }

    private func assertCardsInsideTheirScope(_ frames: [String: CGRect], checks: [HealthCheckScopeCards.Check],
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let scope = try XCTUnwrap(frames["health.scope"], file: file, line: line)
        let viewport = try XCTUnwrap(frames["health.test.viewport"], file: file, line: line)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(scope), file: file, line: line)
        for check in checks {
            let id = check.id.rawValue
            let card = try XCTUnwrap(frames["health.scope.card.\(id)"], file: file, line: line)
            XCTAssertTrue(scope.insetBy(dx: -1, dy: -1).contains(card), file: file, line: line)
            XCTAssertGreaterThan(card.width, 0, file: file, line: line)
            // D64: no display-only glyph or option description; the unknown
            // capability warning still fits and is never replaced by fake data.
            XCTAssertNil(frames["health.scope.icon.\(id)"], file: file, line: line)
            for index in check.details.indices {
                XCTAssertNil(frames["health.scope.detail.\(id).\(index)"], file: file, line: line)
            }
            var childKeys = ["health.scope.title.\(id)"]
            if check.id == .battery && check.details == [L10n.text("内置电池待确认", "Internal battery not confirmed")] {
                childKeys.append("health.scope.availability.battery")
            }
            for key in childKeys {
                let child = try XCTUnwrap(frames[key], file: file, line: line)
                XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(child),
                              "\(key) must stay within its real card", file: file, line: line)
            }
        }
    }
#endif
}

/// Limit the override to the test process's volatile domain. Never change the
/// actual app's saved language or other persistent preferences.
@MainActor
private final class HealthCapabilityLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

#if DEBUG
@MainActor
private final class HealthCapabilityFixture: ObservableObject {
    @Published var availability: InternalBatteryAvailability
    init(_ availability: InternalBatteryAvailability) { self.availability = availability }
}

private struct HealthCapabilityFixtureView: View {
    @ObservedObject var fixture: HealthCapabilityFixture
    let pageHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HealthCheckScopeCards(internalBatteryAvailability: fixture.availability)
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(
                    contentSize: CGSize(width: proxy.size.width, height: pageHeight)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutProbe("health.test.viewport")
        }
    }
}

@MainActor
private final class HealthCapabilityFrameRecorder {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class HealthCapabilityLayoutHost<Root: View> {
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

    func resize(to size: CGSize) {
        window.setContentSize(size)
    }

    func frames(from recorder: HealthCapabilityFrameRecorder, required: Set<String>,
                forbidden: Set<String> = [], expectedWidth: CGFloat? = nil) async throws -> [String: CGRect] {
        var lastFrames: [String: CGRect]?
        var stable = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            let keys = Set(recorder.frames.keys)
            let matchesWidth = expectedWidth.map { width in
                recorder.frames["health.scope"].map { abs($0.width - width) <= 1 } ?? false
            } ?? true
            if required.isSubset(of: keys), forbidden.isDisjoint(with: keys), matchesWidth {
                let current = recorder.frames.filter { required.contains($0.key) }
                if current == lastFrames { stable += 1 } else { stable = 0 }
                lastFrames = current
                if stable >= 2 { return recorder.frames }
            }
        }
        throw NSError(domain: "HealthCapabilityLayoutTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native capability/card layout did not stabilize"])
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
