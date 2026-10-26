import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class StartupBackgroundD217Tests: XCTestCase {
    private func candidates() async throws -> [StartupItemsDomain.Candidate] {
        let home = try TestFileSystem.makeHome(for: self)
        var candidates: [StartupItemsDomain.Candidate] = []
        for (folder, kind, scope, count) in [
            ("Library/LaunchAgents", StartupItemsDomain.ItemKind.userLaunchAgent, StartupItemsDomain.Scope.currentUser, 2),
            ("shared/Library/LaunchAgents", .globalLaunchAgent, .allUsers, 1),
            ("shared/Library/LaunchDaemons", .launchDaemon, .allUsers, 3),
        ] {
            let directory = home.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<count {
                let data = try PropertyListSerialization.data(fromPropertyList: [
                    "Label": "com.example.samevendor.\(kind.rawValue).\(index)",
                    "ProgramArguments": [home.appendingPathComponent("missing-helper").path],
                ], format: .xml, options: 0)
                try data.write(to: directory.appendingPathComponent("\(index).plist"))
            }
            try Data().write(to: directory.appendingPathComponent("ignored.plist.disabled"))
            let child = directory.appendingPathComponent("folder.plist")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data().write(to: child.appendingPathComponent("nested.plist"))
            let scanner = LaunchdPlistScanner(location: .custom(directory: directory, kind: kind, scope: scope))
            candidates += try await scanner.scan(context: StartupScanContext(homeDirectory: home, applicationDirectories: []))
        }
        return candidates
    }

    private func presentation(_ items: [StartupItemsDomain.Item], category: StartupItemsCategory = .all) -> StartupItemsPresentation {
        .make(items: items, query: "", category: category, status: .all, source: .all,
              includeAppleSystem: false, sort: .recommended, includeTechnicalDetails: false)
    }

    func testCountsOnlyTopLevelPlistFilesInAllThreeDirectories() async throws {
        let candidates = try await candidates()
        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(Dictionary(grouping: candidates, by: \.kind).mapValues(\.count),
                       [.userLaunchAgent: 2, .globalLaunchAgent: 1, .launchDaemon: 3])
        XCTAssertTrue(candidates.allSatisfy(\.isCountedBackgroundPlist))
        XCTAssertEqual(presentation(StartupItemMerger().merge(candidates)).summary.background, 6)
    }

    func testOneApplicationAndDeveloperStillCountEveryFileIncludingOurOwnHelper() async throws {
        var candidates = try await candidates()
        for index in candidates.indices {
            candidates[index].attribution = StartupItemsDomain.Attribution(
                applicationBundleIdentifier: "com.example.storagecleaner", applicationURL: nil,
                applicationName: "Our App", developerName: "Same Developer", teamIdentifier: "D217TEAM",
                designatedRequirement: nil, evidence: [.init(kind: .associatedBundleIdentifier,
                    value: "com.example.storagecleaner", confidence: .verified)])
        }
        let grouped = StartupItemMerger().merge(candidates)
        XCTAssertEqual(grouped.count, 1)
        let result = presentation(grouped, category: .background)
        XCTAssertEqual(result.count(for: .background), 6)
        XCTAssertEqual(result.visibleItems.count, 6)
        XCTAssertEqual(Set(result.visibleItems.map(\.id)).count, 6)
        XCTAssertTrue(result.visibleItems.allSatisfy { $0.components.count == 1 })
        XCTAssertEqual(Set(result.visibleItems.flatMap(\.components).map(\.id)), Set(candidates.map(\.id)))
    }

    func testExtraSourcesAndResidualsStayManageableInOtherBackgroundComponents() async throws {
        let base = try await candidates()
        var extra: [StartupItemsDomain.Candidate] = []
        for source in [StartupItemsDomain.ScanSource.backgroundTaskDiagnostic, .serviceManagement, .embeddedService,
                       .launchdRuntime, .privilegedHelper, .orphanDetection] {
            let template = base[0]
            var candidate = StartupItemsDomain.Candidate(id: "extra:\(source.rawValue)", source: source,
                kind: source == .orphanDetection ? .orphanedItem : .appBackgroundTask,
                scope: .applicationBundle, name: source.rawValue, label: nil, plistURL: nil,
                executableURL: nil, applicationURL: nil, configuration: nil, state: template.state,
                attribution: nil, actionCapability: template.actionCapability, diagnosticEvidence: [])
            candidate.state.management = .directlyManageable
            candidate.state.enablement = .enabled
            candidate.actionCapability.canDisableDirectly = true
            extra.append(candidate)
        }
        let grouped = StartupItemMerger().merge(base + extra)
        let result = presentation(grouped, category: .otherBackground)
        XCTAssertEqual(result.count(for: .background), 6)
        XCTAssertEqual(result.visibleItems.count, extra.count)
        XCTAssertEqual(Set(result.visibleItems.flatMap(\.components).map(\.id)), Set(extra.map(\.id)))
        XCTAssertTrue(result.allowsStartupMutationActions)
        XCTAssertTrue(result.visibleItems.allSatisfy(\.isDirectlyManageable))
        XCTAssertEqual(presentation(grouped, category: .background).visibleItems.count, 6)
    }

    func testHelperAvailabilityDoesNotChangeCountOrClaimALowerBound() async throws {
        let items = StartupItemMerger().merge(try await candidates())
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        store.startupDomainItems = items
        for available in [false, true] {
            var coverage = StartupCoverageReport.empty
            coverage.managedItemCoverageAvailable = available
            store.startupCoverage = coverage
            let reading = StartupReadPresentation(coverage: coverage)
            let title = reading.backgroundTitle(count: presentation(items).summary.background)
            XCTAssertEqual(title, L10n.text("发现 6 个后台项目", "6 Background Items Found"))
            XCTAssertFalse(title.contains("至少"))
            XCTAssertFalse(title.contains("At Least"))
            XCTAssertFalse(reading.backgroundDetail.contains("当前只含用户级"))
            let card = SmartCareSummaries.summary(for: .performance, state: .done, store: store, privacy: nil)
            XCTAssertTrue(card.line.contains(title))
            if !available { XCTAssertTrue(card.line.contains(reading.unreadLoginTitle)) }
        }
    }

    func testSystemAndDisabledSuffixEvidenceCannotEnterDirectoryCount() async throws {
        var candidates = try await candidates()
        candidates[0].kind = .systemLaunchAgent
        candidates[1].plistURL = candidates[1].plistURL?.appendingPathExtension("disabled")
        candidates[2].source = .backgroundTaskDiagnostic
        XCTAssertEqual(presentation(StartupItemMerger().merge(candidates)).summary.background, 3)
        XCTAssertEqual(presentation(StartupItemMerger().merge(candidates), category: .otherBackground).visibleItems.count, 3)
    }

    func testHiddenPlistIsStillAFileInTheDirectoryCount() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let file = home.appendingPathComponent(".hidden.plist")
        try Data("malformed but still a plist file".utf8).write(to: file)
        let scanner = LaunchdPlistScanner(location: .custom(directory: home, kind: .userLaunchAgent, scope: .currentUser))
        let result = try await scanner.scan(context: StartupScanContext(homeDirectory: home, applicationDirectories: []))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(presentation(StartupItemMerger().merge(result)).summary.background, 1)
    }

    func testCountedDirectoryPlistIsNotFilteredByAppleAttribution() async throws {
        let scanned = try await candidates()
        var component = try XCTUnwrap(scanned.first)
        component.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/Fixture/helper")
        let items = StartupItemMerger().merge([component])
        XCTAssertTrue(try XCTUnwrap(items.first).isAppleSystem)
        XCTAssertEqual(presentation(items, category: .background).visibleItems.count, 1)
        XCTAssertEqual(StartupItemsPresentation.make(items: items, query: "", filter: .background).summary.background, 1)
    }
}
