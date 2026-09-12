import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateLiveScanTests: XCTestCase {
    func testLiveReadOnlyInventoryAudit() async throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_LIVE_APP_SCAN"] == "1" else {
            throw XCTSkip("Set STORAGE_CLEANER_RUN_LIVE_APP_SCAN=1 for the explicit local inventory audit.")
        }

        // This opt-in host audit mirrors the production source registry. It is
        // still read-only: scanning may load bundled and locally confirmed
        // identities, but it never confirms, revokes, downloads, or installs.
        let registry = OfficialSourceRegistry()
        let resolver = OfficialUpdateSourceResolver(
            registry: registry,
            remoteRefresher: RemoteOfficialSourceRegistryRefresher(configuration: nil)
        )
        let scanner = ApplicationInventoryScanner(sourceResolver: resolver)
        let scannedApplications = try await scanner.scan(
            configuration: ApplicationScanConfiguration(
                includeSpotlightResults: true,
                includeExternalVolumes: false,
                includeHomebrewFormulae: true
            ),
            onProgress: { progress in
                if let detail = progress.detail {
                    print("LIVE_APP_UPDATE_SOURCE \(detail)")
                }
            }
        )
        // Production applies the same local, read-only `mas outdated` merge
        // before presenting and planning updates. This does not run `mas upgrade`.
        let appStoreOutdated = AppUpdateService.appStoreOutdatedByBundleIdentifier()
        let applications = AppUpdateService.mergingAppStoreOutdated(
            appStoreOutdated,
            into: scannedApplications
        )

        XCTAssertFalse(applications.isEmpty)
        XCTAssertEqual(Set(applications.map(\.id)).count, applications.count)
        XCTAssertEqual(
            Set(applications.map { ApplicationPathNormalizer.comparisonKey(for: $0.bundleURL) }).count,
            applications.count
        )

        let providerCounts = Dictionary(grouping: applications, by: \.updateProvider)
            .mapValues(\.count)
        let sourceCounts = Dictionary(grouping: applications) { application in
            application.officialSource?.trustLevel.rawValue ?? "none"
        }
        .mapValues(\.count)
        let payload: [String: Any] = [
            "total": applications.count,
            "updates": applications.filter { $0.availableVersion != nil }.count,
            "automatic": applications.filter(\.canAutomaticallyUpdate).count,
            "website": applications.filter { $0.updateProvider == .officialWebsite }.count,
            "appStore": applications.filter { $0.updateProvider == .macAppStore }.count,
            "unconfirmed": applications.filter { $0.updateStatus == .sourceUnconfirmed }.count,
            "providers": providerCounts.reduce(into: [String: Int]()) { result, pair in
                result[pair.key.rawValue] = pair.value
            },
            "trust": sourceCounts,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("LIVE_APP_UPDATE_AUDIT \(String(decoding: data, as: UTF8.self))")

        let targetedApplications = applications.filter {
            [
                "com.ccswitch.desktop",
                "com.jgraph.drawio.desktop",
                "com.anthropic.claudefordesktop",
            ].contains($0.bundleIdentifier)
        }
        let targetedOneClickPlan = AppUpdateService.oneClickPlan(for: targetedApplications)
        let targetedOneClickIDs = Set(targetedOneClickPlan.automaticApps.map(\.id))
        for application in targetedApplications {
            let disposition = ApplicationUpdatePlanBuilder.destination(for: application)
            let fields = [
                "bundle=\(application.bundleIdentifier)",
                "installed=\(application.installedVersion.marketing)",
                "available=\(application.availableVersion?.marketing ?? "unknown")",
                "provider=\(application.updateProvider.rawValue)",
                "automatic=\(application.canAutomaticallyUpdate)",
                "plan=\(String(describing: disposition))",
            ]
            print("LIVE_APP_UPDATE_TARGET " + fields.joined(separator: " "))
            if ["com.ccswitch.desktop", "com.jgraph.drawio.desktop"]
                .contains(application.bundleIdentifier) {
                XCTAssertEqual(application.updateProvider, .officialWebsite)
                XCTAssertTrue(application.canAutomaticallyUpdate)
            } else if application.bundleIdentifier == "com.anthropic.claudefordesktop" {
                XCTAssertEqual(application.updateProvider, .homebrew)
            }
            XCTAssertTrue(
                disposition == .automatic || disposition == .requiresQuit,
                "Target should be executable by one-click update: \(application.bundleIdentifier)"
            )
            XCTAssertTrue(targetedOneClickIDs.contains(application.id))
        }

        for application in applications where application.updateProvider == .macAppStore
            && application.availableVersion != nil {
            let record = appStoreOutdated[application.bundleIdentifier]
            let productID = MacAppStoreAutomaticUpdateSupport.recordedProductIdentifier(
                in: application.sourceEvidence
            )
            let fields = [
                "bundle=\(application.bundleIdentifier)",
                "installed=\(application.installedVersion.marketing)",
                "available=\(application.availableVersion?.marketing ?? "unknown")",
                "automatic=\(application.canAutomaticallyUpdate)",
                "product=\(productID.map(String.init) ?? "unknown")",
                "urlProduct=\(MacAppStoreAutomaticUpdateSupport.productIdentifier(from: application.appStoreProductURL).map(String.init) ?? "unknown")",
                "path=\(application.bundleURL.path)",
                "masPath=\(record?.bundleURL?.path ?? "unknown")",
                "recordMatch=\(MacAppStoreAutomaticUpdateSupport.matchingRecord(for: application, in: appStoreOutdated) != nil)",
                "identity=\(application.identity.isCompleteForAutomaticUpdates)",
                "evidence=\(application.sourceEvidence.sorted().joined(separator: ","))",
            ]
            print("LIVE_APP_STORE_TARGET " + fields.joined(separator: " "))
        }
    }
}
