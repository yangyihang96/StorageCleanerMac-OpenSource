import XCTest
@testable import StorageCleanerMac

final class UtilityPresentationPerformanceTests: XCTestCase {
    func testEnergyPresentationSortsAndComputesMaximaAndLastID() {
        let low = makeEnergyApp(id: "low", name: "Low", energy: 1, current: 0.2, average: 0.1)
        let high = makeEnergyApp(id: "high", name: "High", energy: 8, current: 3, average: 2)

        let result = EnergyImpactListPresenter.presentation(
            apps: [low, high],
            query: "",
            sortMode: .estimatedEnergy
        )

        XCTAssertEqual(result.apps.map(\.id), ["high", "low"])
        XCTAssertEqual(result.maxEstimatedEnergyWh, 8)
        XCTAssertEqual(result.maxCurrentPowerWatts, 3)
        XCTAssertEqual(result.maxAveragePowerWatts, 2)
        XCTAssertEqual(result.lastID, "low")
    }

    func testEnergyPresentationTrimsQueryAndMatchesNameSourceOrPathIgnoringCase() {
        let nameMatch = makeEnergyApp(
            id: "name",
            name: "MatchToken Name",
            energy: 1,
            current: 1,
            average: 1,
            path: "/Applications/NameOnly.app",
            bundleIdentifier: "com.example.name-only"
        )
        let sourceMatch = makeEnergyApp(
            id: "source",
            name: "Source Candidate",
            energy: 1,
            current: 1,
            average: 1,
            path: "/Applications/SourceOnly.app",
            bundleIdentifier: "com.example.MatchToken"
        )
        let pathMatch = makeEnergyApp(
            id: "path",
            name: "Path Candidate",
            energy: 1,
            current: 1,
            average: 1,
            path: "/Applications/MatchToken.app",
            bundleIdentifier: "com.example.path-only"
        )
        let miss = makeEnergyApp(
            id: "miss",
            name: "Unrelated",
            energy: 1,
            current: 1,
            average: 1,
            path: "/Applications/Unrelated.app",
            bundleIdentifier: "com.example.unrelated"
        )

        let result = EnergyImpactListPresenter.presentation(
            apps: [miss, sourceMatch, pathMatch, nameMatch],
            query: "  mAtChToKeN  ",
            sortMode: .name
        )

        XCTAssertEqual(result.apps.map(\.id), ["name", "path", "source"])
    }

    func testEnergyPresentationExcludesNonApplicationItems() {
        let app = makeEnergyApp(id: "app", name: "App", energy: 1, current: 1, average: 1)
        let process = makeEnergyApp(
            id: "process",
            name: "Process",
            energy: 8,
            current: 3,
            average: 2,
            isApplication: false
        )

        let result = EnergyImpactListPresenter.presentation(
            apps: [process, app],
            query: "",
            sortMode: .estimatedEnergy
        )

        XCTAssertEqual(result.apps.map(\.id), ["app"])
    }

    func testEnergyPresentationClampsEmptyAndNonPositiveMaxima() {
        let empty = EnergyImpactListPresenter.presentation(
            apps: [],
            query: "",
            sortMode: .estimatedEnergy
        )

        XCTAssertEqual(empty.maxEstimatedEnergyWh, 0.001)
        XCTAssertEqual(empty.maxCurrentPowerWatts, 0.001)
        XCTAssertEqual(empty.maxAveragePowerWatts, 0.001)
        XCTAssertNil(empty.lastID)

        let zero = makeEnergyApp(id: "zero", name: "Zero", energy: 0, current: 0, average: 0)
        let negative = makeEnergyApp(id: "negative", name: "Negative", energy: -1, current: -2, average: -3)
        let nonPositive = EnergyImpactListPresenter.presentation(
            apps: [negative, zero],
            query: "",
            sortMode: .estimatedEnergy
        )

        XCTAssertEqual(nonPositive.maxEstimatedEnergyWh, 0.001)
        XCTAssertEqual(nonPositive.maxCurrentPowerWatts, 0.001)
        XCTAssertEqual(nonPositive.maxAveragePowerWatts, 0.001)
    }

    func testUtilityPresentationsExposeStableLastRowWithoutResorting() {
        let items = [makeInstalledApp(name: "B"), makeInstalledApp(name: "A")]
        let result = AppUninstallListPresentation.make(
            apps: items,
            query: "",
            filter: .all,
            sortMode: .name
        )

        XCTAssertEqual(result.apps.map(\.name), ["A", "B"])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.lastID, result.apps.last?.id)
        XCTAssertEqual(result.totalFootprintBytes, 2_000)
    }

    func testAppUpdatePresentationPreservesFilteredSearchOrderAndLastID() {
        let homebrew = makeAppUpdate(
            name: "B",
            source: "Homebrew Source Token",
            method: .homebrew,
            caskToken: "search-token"
        )
        let appStore = makeAppUpdate(name: "A", method: .appStore)

        let all = AppUpdateListPresentation.make(
            apps: [homebrew, appStore],
            query: "",
            filter: .all
        )

        XCTAssertEqual(all.apps.map(\.name), ["B", "A"])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.lastID, appStore.id)

        let filtered = AppUpdateListPresentation.make(
            apps: [homebrew, appStore],
            query: "  SEARCH-TOKEN  ",
            filter: .homebrew
        )

        XCTAssertEqual(filtered.apps.map(\.name), ["B"])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.lastID, homebrew.id)
        XCTAssertEqual(filtered.count(for: .all), 2)
        XCTAssertEqual(filtered.count(for: .homebrew), 1)
        XCTAssertEqual(filtered.count(for: .appStore), 1)
    }

    func testUninstallPresentationInvokesInjectedSourcePresenterOnce() {
        let first = makeInstalledApp(name: "B")
        let returned = makeInstalledApp(name: "A", sizeBytes: 2_000, relatedBytes: 500)
        var callCount = 0

        let result = AppUninstallListPresentation.make(
            apps: [first, returned],
            query: "needle",
            filter: .all,
            sortMode: .name,
            sourcePresenter: { apps, query, filter, sortMode in
                callCount += 1
                XCTAssertEqual(apps.map(\.name), ["B", "A"])
                XCTAssertEqual(query, "needle")
                XCTAssertEqual(filter, .all)
                XCTAssertEqual(sortMode, .name)
                return [returned]
            }
        )

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.apps.map(\.name), ["A"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.lastID, returned.id)
        XCTAssertEqual(result.totalFootprintBytes, 2_500)
    }

    func testAppUpdatePresentationInvokesInjectedSourcePresenterOnce() {
        let first = makeAppUpdate(name: "B", method: .homebrew, caskToken: "b")
        let returned = makeAppUpdate(name: "A", method: .appStore)
        var callCount = 0

        let result = AppUpdateListPresentation.make(
            apps: [first, returned],
            query: "needle",
            filter: .sourceUnconfirmed,
            sourcePresenter: { apps, query, filter in
                callCount += 1
                XCTAssertEqual(apps.map(\.name), ["B", "A"])
                XCTAssertEqual(query, "needle")
                XCTAssertEqual(filter, .sourceUnconfirmed)
                return [returned]
            }
        )

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.apps.map(\.name), ["A"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.lastID, returned.id)
    }

    func testAppUpdatePresentationShowsAppStoreUpdatesWithoutAddingThemToAutomaticUpdates() {
        let homebrew = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "brew-app",
            token: "brew-app",
            path: "/Applications/Brew.app"
        )
        let appStore = makeAppUpdate(name: "Store", method: .appStore)

        let result = AppUpdateApplicationCopyGroupPresentation.make(
            applications: [homebrew, appStore],
            query: ""
        )

        XCTAssertEqual(result.groups.compactMap { $0.primary?.name }, ["brew-app", "Store"])
        XCTAssertEqual(result.automaticApps.map(\.name), ["brew-app"])
    }

    func testAppUpdatePresentationHidesIgnoredUpdatesAndDisplaysTheMatchingDuplicate() throws {
        var primary = makeAppUpdate(name: "Store", method: .manual)
        primary.availableVersion = nil
        primary.versionCheckState = .unavailable

        var appStore = makeAppUpdate(name: "Store Copy", method: .appStore)
        appStore.bundleIdentifier = primary.bundleIdentifier
        appStore.bundleURL = URL(fileURLWithPath: "/Users/test/Applications/Store.app")

        var ignored = makeAppUpdate(name: "Ignored", method: .appStore)
        ignored.updateStatus = .ignored

        let result = AppUpdateApplicationCopyGroupPresentation.make(
            applications: [primary, appStore, ignored],
            query: ""
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(result.groups.first).primary(matching: .updateAvailable)?.id,
            appStore.id
        )
    }

    func testUtilityPresentationsExposeEmptyStableSnapshotsAndFilterCounts() {
        let uninstall = AppUninstallListPresentation.make(
            apps: [],
            query: "",
            filter: .all,
            sortMode: .name
        )

        XCTAssertTrue(uninstall.apps.isEmpty)
        XCTAssertEqual(uninstall.count, 0)
        XCTAssertNil(uninstall.lastID)
        XCTAssertEqual(uninstall.totalFootprintBytes, 0)
        for filter in AppUninstallListFilter.allCases {
            XCTAssertEqual(uninstall.count(for: filter), 0)
        }

        let update = AppUpdateListPresentation.make(
            apps: [],
            query: "",
            filter: .all
        )

        XCTAssertTrue(update.apps.isEmpty)
        XCTAssertEqual(update.count, 0)
        XCTAssertNil(update.lastID)
        for filter in AppUpdateListFilter.allCases {
            XCTAssertEqual(update.count(for: filter), 0)
        }
    }

    func testUninstallPresentationTotalsVisibleAppsButCountsAllRawFilters() {
        let thirdParty = makeInstalledApp(
            name: "ThirdParty",
            sizeBytes: 2_000,
            relatedBytes: 500
        )
        let apple = makeInstalledApp(
            name: "AppleApp",
            bundleIdentifier: "com.apple.test-app",
            sizeBytes: 3_000
        )

        let result = AppUninstallListPresentation.make(
            apps: [thirdParty, apple],
            query: "ThirdParty",
            filter: .thirdParty,
            sortMode: .name
        )

        XCTAssertEqual(result.apps.map(\.name), ["ThirdParty"])
        XCTAssertEqual(result.totalFootprintBytes, 2_500)
        XCTAssertEqual(result.count(for: .all), 2)
        XCTAssertEqual(result.count(for: .thirdParty), 1)
        XCTAssertEqual(result.count(for: .apple), 1)
        XCTAssertEqual(result.count(for: .withLeftovers), 1)
    }

    func testEnergyImpactViewCreatesOnePresentationAndHasNoLegacyComputedLists() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let viewStart = try XCTUnwrap(source.range(of: "struct EnergyImpactView: View {"))
        let sortModeStart = try XCTUnwrap(
            source.range(
                of: "enum EnergyImpactSortMode",
                range: viewStart.upperBound..<source.endIndex
            )
        )
        let viewSource = String(source[viewStart.lowerBound..<sortModeStart.lowerBound])

        XCTAssertEqual(
            viewSource.components(separatedBy: "EnergyImpactListPresenter.presentation(").count - 1,
            1
        )
        XCTAssertFalse(viewSource.contains("private var visibleApps"))
        XCTAssertFalse(viewSource.contains("private var maxEstimatedEnergyWh"))
        XCTAssertFalse(viewSource.contains("private var maxCurrentPowerWatts"))
        XCTAssertFalse(viewSource.contains("private var maxAveragePowerWatts"))
    }

    func testUtilityListViewsCreateOnePresentationAndUseStableRows() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let updaterSource = try sourceText(
            at: "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
        )
        let startupSource = try sourceText(
            at: "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift"
        )
        let presentationSource = try sourceText(
            at: "Sources/StorageCleanerMac/Models/UtilityPresentationModels.swift"
        )
        let uninstallerSource = try sourceSegment(
            source,
            from: "struct AppUninstallerView: View {",
            to: "struct UninstallPreviewSheet: View {"
        )
        let uninstallPresentationSource = try sourceSegment(
            presentationSource,
            from: "struct AppUninstallListPresentation {",
            to: "struct AppUpdateListPresentation {"
        )
        XCTAssertEqual(
            uninstallerSource.components(separatedBy: "AppUninstallListPresentation.make(").count - 1,
            1
        )
        XCTAssertFalse(uninstallerSource.contains("private var apps:"))
        XCTAssertNil(
            uninstallerSource.range(of: #"\.last(?:\?|\b)"#, options: .regularExpression)
        )
        XCTAssertTrue(uninstallerSource.contains("List(selection: $selectedApplicationID)"))
        XCTAssertTrue(uninstallerSource.contains("ForEach(presentation.apps)"))
        XCTAssertTrue(uninstallerSource.contains(".tag(app.id)"))

        XCTAssertEqual(
            updaterSource.components(
                separatedBy: "switch store.appUpdatePresentationState"
            ).count - 1,
            1
        )
        XCTAssertTrue(updaterSource.contains("private var presentationContent: some View"))
        XCTAssertTrue(updaterSource.contains("AppUpdateScanSummaryPage("))
        XCTAssertTrue(updaterSource.contains("AppUpdateManagerPage("))
        XCTAssertTrue(updaterSource.contains("AppUpdateProgressPage("))
        XCTAssertTrue(updaterSource.contains("AppUpdateReportPage("))
        XCTAssertTrue(updaterSource.contains("AppUpdateSessionLogPage("))
        XCTAssertFalse(updaterSource.contains("AppUpdateApplicationCopyGroupPresentation.make("))
        XCTAssertFalse(updaterSource.contains("List(presentation.groups)"))
        XCTAssertFalse(updaterSource.contains("private var visibleApps"))
        XCTAssertFalse(updaterSource.contains("private var copyGroups"))
        XCTAssertFalse(updaterSource.contains("private var automaticApps"))
        XCTAssertFalse(updaterSource.contains("private var websiteApps"))

        XCTAssertEqual(
            startupSource.components(separatedBy: "StartupItemsPresentation.make(").count - 1,
            1
        )
        XCTAssertTrue(
            startupSource.contains("let presentation = StartupItemsPresentation.make(")
        )
        XCTAssertFalse(startupSource.contains("private var presentation: StartupItemsPresentation"))

        XCTAssertTrue(uninstallPresentationSource.contains("let count: Int"))
        XCTAssertTrue(uninstallPresentationSource.contains("let lastID: String?"))
        XCTAssertTrue(uninstallPresentationSource.contains("let totalFootprintBytes: Int64"))
        XCTAssertTrue(uninstallPresentationSource.contains("private init("))
        XCTAssertFalse(source.contains("enum UpdateFilter: String"))
        XCTAssertFalse(updaterSource.contains("primaryFilters"))
        XCTAssertTrue(updaterSource.contains("AppUpdateCatalogFilter"))
        XCTAssertTrue(updaterSource.contains("搜索应用、版本或来源"))
        XCTAssertTrue(updaterSource.contains("Update in App Store"))
        XCTAssertTrue(updaterSource.contains("Open In-App Updater"))
    }

    func testLargeEnergyAndUninstallListsUseLazyContainers() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let energySource = try sourceSegment(
            source,
            from: "struct EnergyImpactView: View {",
            to: "private struct EnergyImpactSummaryGrid: View {"
        )
        let uninstallerSource = try sourceSegment(
            source,
            from: "struct AppUninstallerView: View {",
            to: "struct UninstallPreviewSheet: View {"
        )

        XCTAssertTrue(energySource.contains("LazyVStack(spacing: 0)"))
        XCTAssertTrue(uninstallerSource.contains("List(selection: $selectedApplicationID)"))
    }

    private func makeEnergyApp(
        id: String,
        name: String,
        energy: Double,
        current: Double,
        average: Double,
        path: String? = nil,
        bundleIdentifier: String? = nil,
        isApplication: Bool = true
    ) -> EnergyImpactApp {
        let resolvedPath = path ?? "/Applications/\(name).app"
        return EnergyImpactApp(
            id: id,
            name: name,
            path: resolvedPath,
            iconPath: resolvedPath,
            bundlePath: resolvedPath,
            bundleIdentifier: bundleIdentifier ?? "com.example.\(id)",
            measuredEnergyWh: energy,
            estimatedSupplementEnergyWh: 0,
            estimatedEnergyWh: energy,
            currentPowerWatts: current,
            averagePowerWatts: average,
            cpuPercent: 0,
            diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: 0,
            residentBytes: 0,
            cumulativeCPUSeconds: 0,
            longestRunningSeconds: nil,
            processCount: 1,
            measuredProcessCount: 1,
            processIDs: [1],
            isApplication: isApplication
        )
    }

    private func makeInstalledApp(
        name: String,
        bundleIdentifier: String? = nil,
        sizeBytes: Int64 = 1_000,
        relatedBytes: Int64 = 0
    ) -> InstalledAppItem {
        let relatedItems = relatedBytes > 0
            ? [InstalledAppRelatedItem(path: "/tmp/\(name)-cache", sizeBytes: relatedBytes)]
            : []
        return InstalledAppItem(
            id: "/Applications/\(name).app",
            name: name,
            bundleIdentifier: bundleIdentifier ?? "com.example.\(name.lowercased())",
            path: "/Applications/\(name).app",
            version: "1.0",
            build: "1",
            category: "Test",
            appDescription: "\(name) test app",
            sizeBytes: sizeBytes,
            source: "Applications",
            modifiedAt: nil,
            relatedPaths: relatedItems.map(\.path),
            relatedItems: relatedItems,
            status: .installed
        )
    }

    private func makeAppUpdate(
        name: String,
        source: String = "Test",
        method: AppUpdateMethod,
        caskToken: String? = nil
    ) -> AppUpdateItem {
        AppUpdateItem(
            id: "/Applications/\(name).app",
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            path: "/Applications/\(name).app",
            version: "1.0",
            build: "1",
            source: source,
            method: method,
            feedURL: nil,
            caskToken: caskToken,
            currentVersion: "1.0",
            latestVersion: "2.0",
            modifiedAt: nil
        )
    }

    private func sourceText(at relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSegment(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
