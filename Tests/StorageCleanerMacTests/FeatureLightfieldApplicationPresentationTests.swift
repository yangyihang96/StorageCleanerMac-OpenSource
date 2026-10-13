import Foundation
import XCTest
@testable import StorageCleanerMac

final class FeatureLightfieldApplicationPresentationTests: XCTestCase {
    func testUninstallApprovedAmountsUseTheSameDecimalStorageFormatterInSummaryRowsAndAX() throws {
        let sizes: [Int64] = [21_400_000_000, 7_900_000_000, 5_600_000_000, 4_800_000_000, 1_100_000_000]
        let locale = Locale(identifier: "en_AU")
        XCTAssertEqual(sizes.map { ByteFormat.storageString($0, locale: locale) }, ["21.4 GB", "7.9 GB", "5.6 GB", "4.8 GB", "1.1 GB"])
        let total = sizes.reduce(Int64(0), +)
        XCTAssertEqual(total, 40_800_000_000)
        XCTAssertEqual(FeatureLightfieldAmount.parse(ByteFormat.storageString(total, locale: locale)),
            .init(value: 40.8, unit: "GB", precision: 1, qualifier: ""))
        let page = try text("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertTrue(page.contains("FeatureLightfieldAmount.parse(ByteFormat.storageString(totalBytes))"))
        let rows = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldUninstallList.swift")
        XCTAssertTrue(rows.contains("Text(ByteFormat.storageString(app.sizeBytes))"))
        XCTAssertTrue(rows.contains(".help(ByteFormat.storageString(app.sizeBytes))"))
        XCTAssertTrue(rows.contains(".accessibilityLabel(app.name + \" · \" + app.path + \" · \" + ByteFormat.storageString(app.sizeBytes))"))
    }

    func testResultListCountsOnlyConfirmedUpdatesAndKeepsUnknownAndSystemAppsHonest() {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic", token: "automatic")
        let quit = AppUpdateTestFixtures.strictHomebrewApplication(id: "quit", token: "quit", isRunning: true)
        let authorization = AppUpdateTestFixtures.strictHomebrewApplication(id: "authorization", token: "authorization", requiresAuthorization: true)
        let unknown = AppUpdateTestFixtures.application(id: "unknown", provider: .sparkle,
            status: .latestVersionUnknown, sourceEvidence: ["sparkle-framework"])
        let current = AppUpdateTestFixtures.application(id: "current", status: .upToDate)
        let system = AppUpdateTestFixtures.application(id: "system", provider: .systemManaged, status: .systemManaged, isSystem: true)
        let summary = AppScanSummary(sessionID: UUID(), applications: [automatic, quit, authorization, unknown, current, system])
        let presentation = AppUpdateLightfieldPresentation(summary: summary)
        XCTAssertEqual(presentation.entries.map(\.id), ["automatic", "quit", "authorization"])
        XCTAssertEqual(presentation.metrics.map(\.value), ["1", "1", "1", "1", "1", "0"])
        XCTAssertEqual(summary.systemManagedCount, 1)
        XCTAssertEqual(summary.scannedCount, 6)
        XCTAssertEqual(AppUpdateCatalogSnapshot(summary: summary).entries.map(\.id), ["automatic", "quit", "authorization", "unknown"],
            "Unknown actionable paths must remain available in the existing manager")
    }

    func testEmptyUnknownScanDoesNotClaimEverythingIsCurrent() {
        let unknown = AppUpdateTestFixtures.application(id: "unknown")
        let unresolved = AppUpdateLightfieldPresentation(summary: .init(sessionID: UUID(), applications: [unknown]))
        XCTAssertTrue(unresolved.entries.isEmpty)
        XCTAssertTrue(unresolved.emptyMessage.contains(L10n.text("未发现可确认更新", "No confirmed updates")))
        let current = AppUpdateTestFixtures.application(id: "current", status: .upToDate)
        let finished = AppUpdateLightfieldPresentation(summary: .init(sessionID: UUID(), applications: [current]))
        XCTAssertEqual(finished.emptyMessage, L10n.text("所有应用都是最新版本", "All Apps Are Up to Date"))
    }

    func testApplicationColumnsKeepIndependentVersionPathAndHandlingBounds() {
        for width in [CGFloat(371), 514, 616, 878, 1278, 1998] {
            for kind in [LightfieldApplicationColumns.Kind.uninstall, .updater] {
                let columns = LightfieldApplicationColumns(kind: kind).widths(for: width)
                XCTAssertEqual(columns.count, 4)
                XCTAssertTrue(columns.allSatisfy { $0 > 0 })
                XCTAssertEqual(columns.reduce(0, +) + 48 + 6, width, accuracy: 0.5)
                XCTAssertEqual(columns[0], kind == .uninstall ? 60 : 24)
            }
        }
        XCTAssertEqual(LightfieldApplicationColumns(kind: .updater).widths(for: 878), [24, 380, 274, 146])
    }

    func testResultSourceKeepsChecksAndReviewAwayFromInstallation() throws {
        let source = try text("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift")
        let start = try XCTUnwrap(source.range(of: "case let .scanSummary(summary):"))
        let end = try XCTUnwrap(source.range(of: "case let .managing(snapshot):", range: start.upperBound..<source.endIndex))
        let wiring = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(wiring.contains("onManage: store.showAppUpdateManager"))
        XCTAssertTrue(wiring.contains("onUpdateAll: { store.previewOneClickAppUpdates(); store.confirmOneClickAppUpdates() }"))
        XCTAssertFalse(wiring.contains("request"))
        let pageStart = try XCTUnwrap(source.range(of: "struct AppUpdateScanSummaryPage: View"))
        let pageEnd = try XCTUnwrap(source.range(of: "private struct AppUpdateWarningsView", range: pageStart.upperBound..<source.endIndex))
        let page = String(source[pageStart.lowerBound..<pageEnd.lowerBound])
        XCTAssertTrue(page.contains("action: onUpdateAll"))
        XCTAssertFalse(page.contains("confirmOneClickAppUpdates"))
        XCTAssertTrue(page.contains("value: Double(summary.scannedCount)"))
        XCTAssertTrue(page.contains("metrics: presentation.metrics"))
        for forbidden in ["GlassToolbarButton", "FeatureWorkspaceSurface", "ContentPanel", "LazyVGrid", "AppUpdateSummaryMetric", "Image(systemName:", "扫描完成"] {
            XCTAssertFalse(page.contains(forbidden), forbidden)
        }
        let rows = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldApplicationRows.swift")
        let adapter = try text("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdateLightfieldPresentation.swift")
        for value in [rows, adapter] {
            for forbidden in [".ultraThinMaterial", "glassEffect", "ContentPanel", "Color(nsColor:", "requestAppUpdate("] {
                XCTAssertFalse(value.contains(forbidden), forbidden)
            }
        }
        XCTAssertTrue(adapter.contains(".font(.system(size: 12.5, design: .monospaced))"))
        XCTAssertTrue(adapter.contains("LightfieldStatusGlyph(status: handling.status, tone:"))
        for icon in ["updaterPackages", "updaterStore", "updaterUpdateFeed", "updaterWebsite"] {
            XCTAssertTrue(source.contains("icon: ." + icon), icon)
        }
        let landing = try text("Sources/StorageCleanerMac/Views/AppUninstallScanLandingView.swift")
        for icon in ["uninstallApplication", "uninstallContainers", "uninstallRelatedFiles"] {
            XCTAssertTrue(landing.contains("icon: ." + icon), icon)
        }
    }

    private func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
