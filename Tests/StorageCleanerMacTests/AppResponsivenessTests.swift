import XCTest
@testable import StorageCleanerMac

final class AppResponsivenessTests: XCTestCase {
    func testBenchmarkHardwareIdentityAcceptsCurrentAndFutureAppleChipNames() {
        XCTAssertEqual(
            CPUPerformanceStateService.resolvedProcessorModel(
                topologyModel: "  Apple   M3 Max ",
                sysctlBrand: "Apple M2"
            ),
            "Apple M3 Max"
        )
        XCTAssertEqual(
            CPUPerformanceStateService.resolvedProcessorModel(
                topologyModel: nil,
                sysctlBrand: " Apple M9 Ultra "
            ),
            "Apple M9 Ultra"
        )
        XCTAssertNil(
            CPUPerformanceStateService.resolvedProcessorModel(
                topologyModel: "",
                sysctlBrand: " "
            )
        )
    }

    func testInactiveFeatureStoresDoNotInvalidateTheMainNavigationShell() throws {
        let content = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ContentView.swift"
        )

        for property in [
            "computerHealthStore",
            "networkSpeedTestStore",
            "privacyHistoryStore",
            "macBenchmarkStore",
            "macBenchmarkLeaderboardStore",
            "heavyWorkActivityStore",
        ] {
            XCTAssertFalse(content.contains("@ObservedObject private var \(property)"))
            XCTAssertFalse(content.contains("@ObservedObject var \(property)"))
        }
        XCTAssertTrue(content.contains("@ObservedObject var store: ScanStore"))
        XCTAssertTrue(content.contains("private let macBenchmarkStore: MacBenchmarkStore"))
        XCTAssertTrue(content.contains("@StateObject private var browserPrivacyStore: BrowserPrivacyStore"))
    }

    func testSettingsAndBenchmarkMountExpensiveContentOnDemand() throws {
        let settings = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SettingsView.swift"
        )
        let benchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )

        XCTAssertTrue(settings.contains("settingsPane(for: selectedCategory)"))
        XCTAssertTrue(settings.contains("private var settingsSidebar: some View"))
        XCTAssertTrue(settings.contains("settingsSections(for: category)"))
        XCTAssertTrue(settings.contains("refresh(category: selectedCategory)"))
        XCTAssertTrue(settings.contains("ScanHistorySummary(entries: [])"))

        XCTAssertTrue(benchmark.contains("LazyVStack("))
        XCTAssertTrue(benchmark.contains("private let leaderboardStore"))
        XCTAssertFalse(benchmark.contains("DisclosureGroup"))
        XCTAssertFalse(benchmark.contains("@ObservedObject private var leaderboardStore"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(at relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
