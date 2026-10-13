import Foundation
import XCTest
@testable import StorageCleanerMac

final class TestDataIsolationTests: XCTestCase {
    @MainActor
    func testScanStoreFactoryUsesTemporaryEnergyPowerHistoryAndPreferences() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let defaults = TestPreferenceDomain.make(for: self)
        let powerURL = home.appendingPathComponent("Monitoring/MenuBarPowerHistory.json")
        let power = MenuBarPowerHistoryPoint(date: Date().addingTimeInterval(-1), chargePercent: 63,
            batteryPowerWatts: -10, isCharging: false, powerSource: .batteryPower)
        try MenuBarPowerHistoryStore.save([power], to: powerURL)
        let store = try ScanStore.makeForTests(for: self, dataDirectory: home, preferences: defaults)
        XCTAssertEqual(store.menuBarAuxiliaryMonitorState.powerHistory, [power])
        store.menuBarRefreshInterval = .twoSeconds
        XCTAssertEqual(defaults.string(forKey: "menuBar.refreshInterval"), "twoSeconds")

        let now = Date()
        for (seconds, date) in [(100.0, now.addingTimeInterval(-60)), (160.0, now)] {
            store.systemEnergyAccumulator.record(SystemEnergyPowerSample(monotonicSeconds: seconds,
                wallClock: date, watts: 10, powerSource: .battery, confidence: .measured, source: "fixture"))
        }
        await store.stopAndFlushSystemEnergyMonitoring()
        let saved = try XCTUnwrap(SystemEnergySessionStore.load(from: home.appendingPathComponent("SystemEnergySession-v1.json")))
        XCTAssertEqual(saved.totalWattHours, 10.0 / 60, accuracy: 0.000_001)
        XCTAssertEqual(saved.totalWattHours, store.systemEnergyAccumulator.snapshot.totalWattHours)
        XCTAssertTrue(FileManager.default.fileExists(atPath: powerURL.path))
    }

    func testSamplingGapsRoundTripThroughAnIsolatedPreferenceDomain() throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let origin = Date()
        let gaps = MenuBarSamplingGaps(defaults: defaults)
        gaps.begin(.paused, at: origin)
        gaps.end(.paused, at: origin.addingTimeInterval(10))
        XCTAssertEqual(MenuBarSamplingGaps(defaults: defaults).intervals(at: origin.addingTimeInterval(20)),
                       [DateInterval(start: origin, duration: 10)])
        let another = MenuBarSamplingGaps(defaults: TestPreferenceDomain.make(for: self))
        XCTAssertTrue(another.intervals().isEmpty)
    }

    func testInjectedHomeKeepsItsBoundaryAndRejectsUserSymlinks() throws {
        let home = try TestFileSystem.makeOperationHome(for: self)
        let outside = try TestFileSystem.makeOperationHome(for: self)
        let dataHome = try TestFileSystem.makeHome(for: self)
        let isolatedRoot = home.deletingLastPathComponent()
        XCTAssertEqual(home.lastPathComponent, "home")
        XCTAssertTrue(isolatedRoot.lastPathComponent.hasPrefix(".storage-cleaner-"))
        XCTAssertEqual(isolatedRoot.deletingLastPathComponent(), FileManager.default.homeDirectoryForCurrentUser)
        let file = home.appendingPathComponent("Library/Caches/owned")
        let foreign = outside.appendingPathComponent("Library/Caches/foreign")
        try Data("owned".utf8).write(to: file)
        try Data("keep".utf8).write(to: foreign)
        XCTAssertTrue(PathSafety.isLexicallyInsideHome(file.path, homeDirectory: home))
        XCTAssertTrue(PathSafety.isInsideHome(file.path, homeDirectory: home))
        XCTAssertFalse(PathSafety.isInsideHome(foreign.path, homeDirectory: home))
        XCTAssertTrue(PathSafety.isInsideHome(file.path), "操作夹具必须满足原有生产 home 边界")
        XCTAssertFalse(PathSafety.isInsideHome(dataHome.path), "普通数据的系统临时根仍在真实 home 之外")
        XCTAssertFalse(PathSafety.containsSymbolicLinkComponent(in: file.path), "隔离操作目录不应经过任何符号链接")
        XCTAssertFalse(try FoundationReadOnlyFileSystem().snapshot(at: file).hasSymbolicLinkComponent)
        let link = home.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertTrue(PathSafety.isLexicallyInsideHome(link.path, homeDirectory: home))
        XCTAssertFalse(PathSafety.isInsideHome(link.path, homeDirectory: home))
        XCTAssertTrue(PathSafety.containsSymbolicLinkComponent(in: link.path))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "keep")
    }

    func testStorageAnalysisAcceptsIsolatedHomeAndRejectsUserLinkRoots() throws {
        let home = try TestFileSystem.makeOperationHome(for: self)
        try Data("analysis".utf8).write(to: home.appendingPathComponent("file.bin"))
        let target = StorageMapScanTarget(path: home.path, title: "Temporary Home", kind: .homeDirectory)
        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
        XCTAssertEqual(result.index.rootPath, home.path)
        XCTAssertNotNil(result.index.indexedEntry(at: home.appendingPathComponent("file.bin").path))
        let outside = try TestFileSystem.makeOperationHome(for: self)
        let alias = outside.appendingPathComponent("user-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        let linked = StorageMapScanTarget(path: alias.path, title: "User Link", kind: .homeDirectory)
        XCTAssertThrowsError(try DiskScanner(excludedPaths: []).storageMapAnalysis(target: linked)) { error in
            guard case StorageMapAnalysisError.symbolicLinkPath = error else { return XCTFail("\(error)") }
        }
    }

    func testProductionPathGuardsKeepTheirOriginalSymlinkChecks() throws {
        let safety = try source("Support/PathSafety.swift")
        XCTAssertTrue(safety.contains("fileType == .typeSymbolicLink"))
        XCTAssertFalse(safety.contains("OperationFileLock.systemAliasResolvedPath"))
        let scanner = try source("Services/DiskScanner.swift")
        XCTAssertEqual(scanner.components(separatedBy: "guard PathSafety.normalizedPath(rootPath) == rootPath else").count - 1, 2)
        let recovery = try source("Services/RecordedCleanupRecovery.swift")
        XCTAssertTrue(recovery.contains("for component in url.pathComponents.dropFirst()"))
        XCTAssertTrue(recovery.contains("O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertFalse(recovery.contains("OperationFileLock.systemAliasResolvedPath"))
    }

    func testProductionDefaultsKeepTheOriginalLocationsAndSharedPreferences() throws {
        let store = try source("Stores/ScanStore.swift")
        for declaration in [
            "systemEnergyAccumulator: SystemEnergyAccumulator? = nil",
            "menuBarPowerHistoryURL: URL? = MenuBarPowerHistoryStore.defaultURL",
            "samplingGaps: MenuBarSamplingGaps = .shared",
            "preferences: UserDefaults = .standard",
            "fileAnalysisTrashEnvironment: FileAnalysisTrashEnvironment = .live",
            "trashEnvironment: fileAnalysisTrashEnvironment",
            "systemEnergyAccumulator ?? SystemEnergyAccumulator(samplingGaps: samplingGaps)",
            "powerHistoryURL: metricHistoryStore == nil ? menuBarPowerHistoryURL : nil"
        ] {
            XCTAssertTrue(compact(store).contains(compact(declaration)), declaration)
        }
        let energy = try source("Services/SystemEnergyAccumulator.swift")
        XCTAssertTrue(energy.contains("fileURL: URL? = SystemEnergyAccumulatorLocation.defaultURL"))
        XCTAssertTrue(energy.contains("samplingGaps: MenuBarSamplingGaps = .shared"))
        XCTAssertTrue(try source("Support/MenuBarSamplingGaps.swift").contains("static let shared = MenuBarSamplingGaps(defaults: .standard)"))
        XCTAssertEqual(SystemEnergyAccumulatorLocation.defaultURL,
                       AppDataDirectories.applicationSupportRoot.appendingPathComponent("SystemEnergySession-v1.json"))
        XCTAssertEqual(MenuBarPowerHistoryStore.defaultURL,
                       AppDataDirectories.applicationSupportRoot.appendingPathComponent("Monitoring", isDirectory: true)
                        .appendingPathComponent("MenuBarPowerHistory.json"))
    }

    func testEveryInjectedRootStillDefaultsToTheCurrentUserHomeOrLiveJournal() throws {
        let homeDefault = "homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser"
        // 包括原有 userTrashURL / restoreFromTrash，锁定所有三个清理重载的根默认值。
        for (file, count) in [
            ("Support/PathSafety.swift", 2),
            ("Services/CleanupService.swift", 5),
            ("Services/AppUninstallService.swift", 4),
            ("Services/UninstallOwnershipVerifier.swift", 3),
            ("Services/UninstallExecution.swift", 2),
            ("Services/ExternalDriveMigrationService.swift", 2)
        ] {
            XCTAssertEqual(try source(file).components(separatedBy: homeDefault).count - 1, count, file)
        }
        let model = try source("Models/SystemModels.swift")
        XCTAssertTrue(model.contains("canMoveToTrash(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)"))
        XCTAssertTrue(try source("Features/DuplicateFiles/Stores/DuplicateFilesStore.swift")
            .contains("userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser"))
        let recovery = try source("Services/RecordedCleanupRecovery.swift")
        XCTAssertEqual(recovery.components(separatedBy: "userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser").count - 1, 2)
        let reports = compact(try source("Services/CleanupMigration.swift"))
        XCTAssertTrue(reports.contains(compact("static func summaryPage(after cursor: CleanupReportIndex.Cursor? = nil, limit: Int = 40, journal: CleanupReportJournal = .live)")))
        XCTAssertTrue(reports.contains(compact("static func report(planID: CleanPlanID, journal: CleanupReportJournal = .live)")))
    }

    func testProductionWriteOperationDefaultsKeepTheirOriginalImplementations() throws {
        let store = try source("Stores/ScanStore.swift")
        XCTAssertTrue(store.contains("scanHeavyWorkOperations: ScanHeavyWorkService.Operations = .init()"))
        XCTAssertTrue(store.contains("uninstallMoves: UninstallMoveEnvironment = .live"))
        let operations = try source("Services/ScanHeavyWorkService.swift")
        for implementation in [
            "try CleanupService.moveToTrash(item, allowedPaths: allowedPaths)",
            "try CleanupService.emptyUserTrash()", "CleanupService.restoreFromTrash(records)",
            "await MemoryOptimizerService.optimize()",
            "try await ScanHeavyWorkService.runCancellableHomebrewUpgrade(for: apps)",
            "AppUpdateService.prepareOneClickUpdate(plan, opensAppStore: true)",
            "operations: Operations = Operations()"
        ] { XCTAssertTrue(operations.contains(implementation), implementation) }
        let uninstall = compact(try source("Services/UninstallExecution.swift"))
        XCTAssertTrue(uninstall.contains(compact("static let live = UninstallMoveEnvironment(recycle: { try await NativeApplicationRecycler.recycle($0) }, authorization: .live)")))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }

    private func compact(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
