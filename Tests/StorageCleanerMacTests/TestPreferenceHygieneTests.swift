import Foundation
import XCTest
@testable import StorageCleanerMac

final class TestPreferenceHygieneTests: XCTestCase {
    func testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults() throws {
        let defaultRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let testsRoot = ProcessInfo.processInfo.environment["STORAGE_CLEANER_TEST_SOURCE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot
        XCTAssertEqual(testsRoot.lastPathComponent, "Tests", "守卫只能检查 Tests 源码或其临时副本")
        XCTAssertEqual(try Self.violations(inTestsDirectory: testsRoot), [])
    }

    private static func violations(inTestsDirectory testsRoot: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" { files.append(file) }
        XCTAssertFalse(files.isEmpty, "必须能读取测试源码，不能静默跳过守卫")
        return try files.sorted(by: { $0.path < $1.path }).flatMap { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = String(file.path.dropFirst(testsRoot.path.count + 1))
            return violations(in: source, path: relativePath).map { relativePath + ": " + $0 }
        }
    }

    func testGuardRejectsDirectAliasedAndMultilinePersistentWrites() {
        for source in [
            "UserDefaults(suiteName: \"unsafe\")",
            "UserDefaults\n(suiteName : \"unsafe\")",
            "NSUserDefaults(suiteName: \"unsafe\")",
            "UserDefaults.standard.set(true, forKey: \"key\")",
            "UserDefaults.standard\n.removeObject(forKey: \"key\")",
            "let defaults: UserDefaults = UserDefaults.standard\ndefaults.setValue(1, forKey: \"key\")",
            "let defaults: UserDefaults = .standard\ndefaults.set(true, forKey: \"key\")",
            "let defaults = UserDefaults.standard\ndefaults.removePersistentDomain(forName: \"key\")",
            "let original = UserDefaults.standard\nlet alias = original\nalias.setPersistentDomain([:], forName: \"key\")",
            "UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)",
            #"let value = "\(UserDefaults.standard.set(true, forKey: "key"))""#
        ] {
            XCTAssertFalse(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source)
        }
    }

    func testGuardIgnoresReadOnlyAccessCommentsAndSourceAssertionLiterals() {
        let source = #"""
        // UserDefaults(suiteName: "comment")
        /* outer /* UserDefaults.standard.set(true, forKey: "comment") */ */
        let quoted = "UserDefaults.standard.removeObject(forKey: \"literal\")"
        let raw = #"UserDefaults(suiteName: "literal")"#
        let multiline = """
        UserDefaults.standard.set(true, forKey: "literal")
        """
        let defaults = UserDefaults.standard
        _ = defaults.data(forKey: "key")
        _ = UserDefaults.standard.string(forKey: "key")
        """#
        XCTAssertEqual(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift"), [])
    }


    func testGuardRejectsInitializerDefaultsCFPreferencesAndLiveScanStoreBypasses() {
        for source in [
            #"UserDefaults.init(suiteName: "unsafe")"#,
            "UserDefaults()",
            "UserDefaults.init()",
            #"func relay(defaults: UserDefaults = .standard) { helper(defaults) }"#,
            #"let defaults: UserDefaults = .init(suiteName: "unsafe")"#,
            #"func write(defaults: UserDefaults = .standard) { defaults.set(1, forKey: "key") }"#,
            #"func write(defaults: UserDefaults = UserDefaults.standard) { defaults.removeObject(forKey: "key") }"#,
            #"var defaults: UserDefaults; defaults = UserDefaults.standard; defaults.register(defaults: [:])"#,
            #"CFPreferencesSetAppValue("key", true, "domain")"#,
            #"CFPreferencesSetMultiple([:], [], "domain", "user", "host")"#,
            #"CFPreferencesAppSynchronize("domain")"#,
            "let store = ScanStore()",
            "let store = ScanStore.init(cleanReportLoader: { [] })",
            "let store: ScanStore = .init()",
            "MenuBarSamplingGaps.shared.end(.paused)",
            "FanControlCoordinator()",
            "SystemEnergyAccumulator(fileURL: nil)",
            "MenuBarAuxiliaryMonitorState()",
            "LargeFilesStore(storageAnalysisOperation: { _, _ in previous })",
            "LargeFilesStore(storageAnalysisOperation: { _, _ in previous }, trashEnvironment: .live)"
        ] {
            XCTAssertFalse(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source)
        }
    }

    func testGuardRejectsRealLibraryPathsButAllowsTemporaryHomeRelativePaths() {
        let cache = "~" + "/Library/Caches/fixture"
        let appData = "Application Support/" + "StorageCleanerMac"
        for source in [
            "let path = \"\(cache)\"",
            "let path = \"~/Library/\(appData)/fixture\"",
            #"let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/x")"#,
            #"let home = FileManager.default.homeDirectoryForCurrentUser; let root = home.appendingPathComponent("Library/Preferences/x")"#,
            #"let home = NSHomeDirectory(); let root = home + "/Library/Caches/x""#,
            #"let root = "\(PathSafety.homePath)/Library/Caches/x""#
        ] {
            let write = source + "; try Data().write(to: root); try Data().write(toFile: path)"
            XCTAssertFalse(Self.violations(in: write, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source)
        }
        XCTAssertEqual(Self.violations(in:
            #"let home = TestFileSystem.makeHome(for: self); let root = home.appendingPathComponent("Library/Caches/x")"#,
            path: "StorageCleanerMacTests/NewTests.swift"), [])
    }

    func testGuardRejectsInferredInitializersAndLiveOverrideAliases() {
        for source in [
            "let defaults: UserDefaults = .init()",
            "var defaults: UserDefaults; defaults = .init()",
            "func factory() -> UserDefaults { .init() }",
            "let accumulator: SystemEnergyAccumulator = .init(fileURL: nil)",
            "let prefs = UserDefaults.standard; FanControlCoordinator(defaults: prefs)",
            "let prefs = UserDefaults.standard; let alias = prefs; let fan: FanControlCoordinator = .init(defaults: alias)",
            "let gaps = MenuBarSamplingGaps.shared; SystemEnergyAccumulator(fileURL: nil, samplingGaps: gaps)",
            "ScanStore.makeForTests(for: self, preferences: .standard)",
            "ScanStore.makeForTests(for: self, preferences: .init())",
            "let file = MenuBarPowerHistoryStore.defaultURL; ScanStore.makeForTests(for: self, menuBarPowerHistoryURL: file)",
            "ScanStore.makeForTests(for: self, samplingGaps: .shared)",
            "ScanStore.makeForTests(for: self, fileAnalysisTrashEnvironment: .live)",
            "let prefs = UserDefaults.standard; ScanStore.makeForTests(for: self, cleanupPreferences: prefs)",
            "let moves = UninstallMoveEnvironment.live; ScanStore.makeForTests(for: self, uninstallMoves: moves)",
            "ScanStore.makeForTests(for: self, scanHeavyWorkOperations: .init(scan: { _, _ in result }))",
            "let operations: ScanHeavyWorkService.Operations = .init(scan: { _, _ in result })",
            "ScanHeavyWorkService(operations: .init(scan: { _, _ in result }))",
            "ScanHeavyWorkService()"
        ] {
            XCTAssertFalse(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source)
        }
        XCTAssertEqual(Self.violations(in: "let operations = TestOperationFactory(for: self).scanOperations(scan: { _, _ in result })",
                                       path: "StorageCleanerMacTests/NewTests.swift"), [])
    }

    func testFactoryExceptionRequiresEveryIsolationDependency() {
        let labels = ["preferences", "scanHistoryDefaults", "cleanupPreferences", "samplingGaps", "systemEnergyAccumulator",
                      "menuBarPowerHistoryURL", "scanHeavyWorkOperations", "uninstallMoves", "fileAnalysisTrashEnvironment",
                      "cleanupExecutor", "cleanupRecoveryService", "cleanupOwnerQuitService", "memoryCoordinator",
                      "cleanupUserHomeURL", "operationJournal", "operationTrashURL", "historyLoader", "cleanReportLoader",
                      "restoreSavedAccessOperation", "interruptedOperationReconciler", "startupItemManager",
                      "applicationUpdateCoordinator", "applicationUpdateGracefulQuitRequester", "applicationUpdateRelauncher",
                      "websiteUpdateWorkflow", "fanControlProvider"]
        let path = "StorageCleanerMacTests/TestScanStoreFactory.swift"
        func source(omitting missing: String? = nil, injectedValue: String = "isolated") -> String {
            "let dataRoot = try TestFileSystem.requireOwnedData(candidate, for: self); let operationHome = try TestFileSystem.requireOwned(candidate, for: self); let isolated = operationHome; return ScanStore(" + labels.filter { $0 != missing }.map { "\($0): \(injectedValue)" }.joined(separator: ", ") + ")"
        }
        XCTAssertEqual(Self.violations(in: source(), path: path), [])
        XCTAssertFalse(Self.violations(in: "return ScanStore()", path: path).isEmpty)
        for label in labels {
            XCTAssertFalse(Self.violations(in: source(omitting: label), path: path).isEmpty, label)
        }
        for value in ["nil", ".standard", ".shared", ".live"] {
            XCTAssertFalse(Self.violations(in: source(injectedValue: value), path: path).isEmpty, value)
        }
    }

    func testFactoryRequiresNonnilProvenanceAndCheckedOwnership() throws {
        let factoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TestScanStoreFactory.swift")
        let factory = try String(contentsOf: factoryURL, encoding: .utf8)
        let path = "StorageCleanerMacTests/TestScanStoreFactory.swift"
        XCTAssertEqual(Self.violations(in: factory, path: path), [])
        let fallback = "systemEnergyAccumulator ?? SystemEnergyAccumulator("
        let start = try XCTUnwrap(factory.range(of: fallback))
        let tail = try XCTUnwrap(factory.range(of: "            menuBarPowerHistoryURL:", range: start.upperBound..<factory.endIndex))
        let argument = start.lowerBound..<tail.lowerBound
        for unsafe in ["accumulator", "relay", "relay ?? nil"] {
            var copy = factory
            copy.replaceSubrange(argument, with: unsafe + ",\n")
            copy = "let accumulator: SystemEnergyAccumulator? = nil; var relay: SystemEnergyAccumulator?;\n" + copy
            XCTAssertFalse(Self.violations(in: copy, path: path).isEmpty, unsafe)
        }
        var parenthesizedFallback = factory
        parenthesizedFallback.replaceSubrange(argument, with:
            "(systemEnergyAccumulator ?? SystemEnergyAccumulator(fileURL: dataRoot.appendingPathComponent(\"fixture.json\"), samplingGaps: gaps, sampleProvider: { nil })),\n")
        XCTAssertEqual(Self.violations(in: parenthesizedFallback, path: path), [])
        let labelShadow = #"let store = UserDefaults.standard; let payload = Box(store: isolated); payload.set(1, forKey: "key")"#
        XCTAssertEqual(Self.violations(in: labelShadow, path: "StorageCleanerMacTests/NewTests.swift"), [])
        let valueReference = #"let store = UserDefaults.standard; let payload = Box(store: store); payload.set(1, forKey: "key")"#
        XCTAssertFalse(Self.violations(in: valueReference, path: "StorageCleanerMacTests/NewTests.swift").isEmpty)
        let dictionaryReference = #"let store = UserDefaults.standard; let payload = Box(values: [store: isolated]); payload.set(1, forKey: "key")"#
        XCTAssertFalse(Self.violations(in: dictionaryReference, path: "StorageCleanerMacTests/NewTests.swift").isEmpty)
        for source in [
            "ScanStore.makeForTests(for: self, cleanupUserHomeURL: FileManager.default.homeDirectoryForCurrentUser)",
            #"let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"); ScanStore.makeForTests(for: self, operationTrashURL: root)"#,
            #"let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("receipts"); ScanStore.makeForTests(for: self, operationJournal: CleanupReportJournal(directory: root))"#,
            "ScanStore.makeForTests(for: self, fanControlProvider: { FanControlCoordinator.shared })"
        ] { XCTAssertFalse(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source) }
    }

    func testBranchRebindingMembersAndParenthesizedReceiversKeepPossibleSources() {
        let path = "StorageCleanerMacTests/NewTests.swift"
        for source in [
            #"var prefs = TestPreferenceDomain.make(for: self); if condition { prefs = UserDefaults.standard }; prefs.set(1, forKey: "key")"#,
            #"var prefs = TestPreferenceDomain.make(for: self); if condition { prefs = UserDefaults.standard } else { prefs = TestPreferenceDomain.make(for: self) }; prefs.set(1, forKey: "key")"#,
            #"class Fixture { var prefs: UserDefaults; func write() { self.prefs = UserDefaults.standard; self.prefs.set(1, forKey: "key") } }"#,
            #"class Fixture { var prefs: UserDefaults; func write() { if condition { self.prefs = UserDefaults.standard }; self.prefs.set(1, forKey: "key") } }"#,
            #"(UserDefaults.standard).set(1, forKey: "key")"#,
            #"let prefs = UserDefaults.standard; ((prefs)).removeObject(forKey: "key")"#
        ] { XCTAssertFalse(Self.violations(in: source, path: path).isEmpty, source) }
        for source in [
            #"var prefs = UserDefaults.standard; if condition { prefs = UserDefaults.standard }; prefs = TestPreferenceDomain.make(for: self); prefs.set(1, forKey: "key")"#,
            #"class Fixture { var prefs: UserDefaults; func read() { self.prefs = UserDefaults.standard }; func write() { let prefs = TestPreferenceDomain.make(for: self); prefs.set(1, forKey: "key") } }"#,
            #"let prefs = UserDefaults.standard; run { prefs in (prefs).set(1, forKey: "key") }"#
        ] { XCTAssertEqual(Self.violations(in: source, path: path), [], source) }
    }

    func testLibraryComponentsResolveConstantsAndUnknownRealRootRequiresIsolationAtWrites() {
        let path = "StorageCleanerMacTests/NewTests.swift"
        for prefix in [
            #"let component = "Library"; let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(component).appendingPathComponent("Caches")"#,
            #"let name = "Library"; let component = name; let home = FileManager.default.homeDirectoryForCurrentUser; let root = home.appendingPathComponent(component).appendingPathComponent("Caches")"#,
            #"let component = externalValue; let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(component)"#
        ] {
            XCTAssertFalse(Self.violations(in: prefix + "; try Data().write(to: root)", path: path).isEmpty, prefix)
            XCTAssertEqual(Self.violations(in: prefix + "; _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)", path: path), [], prefix)
        }
        let isolated = #"let home = try TestFileSystem.makeOperationHome(for: self); let component = externalValue; let root = home.appendingPathComponent(component); try Data().write(to: root)"#
        XCTAssertEqual(Self.violations(in: isolated, path: path), [])
    }

    func testStandardAliasesRespectFunctionClosureShadowingAndRebinding() {
        let allowed = #"""
        func read() { let defaults = UserDefaults.standard; _ = defaults.string(forKey: "key") }
        func write() { let defaults = TestPreferenceDomain.make(for: self); defaults.set(1, forKey: "key") }
        let defaults = UserDefaults.standard
        run { defaults in defaults.set(2, forKey: "key") }
        run { @MainActor (defaults: UserDefaults) -> Void in defaults.set(2, forKey: "key") }
        run { let defaults = TestPreferenceDomain.make(for: self); defaults.set(3, forKey: "key") }
        func parameter(defaults: UserDefaults) { defaults.set(4, forKey: "key") }
        var alias = UserDefaults.standard
        alias = TestPreferenceDomain.make(for: self)
        alias.set(5, forKey: "key")
        """#
        XCTAssertEqual(Self.violations(in: allowed, path: "StorageCleanerMacTests/NewTests.swift"), [])
        for source in [
            #"let prefs = UserDefaults.standard; run { prefs.set(1, forKey: "key") }"#,
            #"let prefs = UserDefaults.standard; run { [captured = prefs] in captured.removeObject(forKey: "key") }"#,
            #"let prefs = UserDefaults.standard; run { [prefs] in prefs.set(1, forKey: "key") }"#,
            #"let prefs = UserDefaults.standard; run { let prefs = TestPreferenceDomain.make(for: self) }; prefs.set(1, forKey: "key")"#,
            #"var prefs = TestPreferenceDomain.make(for: self); prefs = UserDefaults.standard; prefs.set(1, forKey: "key")"#,
            #"class Fixture { func write() { let prefs = TestPreferenceDomain.make(for: self); self.prefs.set(1, forKey: "key") }; let prefs = UserDefaults.standard }"#
        ] {
            XCTAssertFalse(Self.violations(in: source, path: "StorageCleanerMacTests/NewTests.swift").isEmpty, source)
        }
    }

    func testLibrarySystemDirectoriesAndSegmentedPathsAreCheckedAtWrites() {
        let path = "StorageCleanerMacTests/NewTests.swift"
        for directory in ["cachesDirectory", "applicationSupportDirectory", "libraryDirectory", "preferencePanesDirectory",
                          "applicationScriptsDirectory", "autosavedInformationDirectory"] {
            let source = "let root = FileManager.default.urls(for: .\(directory), in: .userDomainMask).first!"
            XCTAssertEqual(Self.violations(in: source + "\n_ = root.path", path: path), [], "只读取地址不应误报")
            for write in ["try Data().write(to: root)", "try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)",
                          "try FileManager.default.removeItem(at: root)", "TestFileSystem.remove(root)"] {
                XCTAssertFalse(Self.violations(in: source + "\n" + write, path: path).isEmpty, directory + write)
            }
        }
        for source in [
            #"let home = FileManager.default.homeDirectoryForCurrentUser; let library = home.appendingPathComponent("Library"); let caches = library.appendingPathComponent("Caches"); try Data().write(to: caches.appendingPathComponent("fixture"))"#,
            #"let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").appendingPathComponent("Application Support"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)"#,
            #"let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)"#,
            #"let home = NSHomeDirectory(); let path = home + "/Library/Preferences/fixture"; try Data().write(to: URL(fileURLWithPath: path))"#
        ] {
            XCTAssertFalse(Self.violations(in: source, path: path).isEmpty, source)
        }
        XCTAssertEqual(Self.violations(in: #"let home = try TestFileSystem.makeOperationHome(for: self); let library = home.appendingPathComponent("Library"); let root = library.appendingPathComponent("Caches"); try Data().write(to: root.appendingPathComponent("fixture"))"#, path: path), [])
        let readOnly = #"let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences"); _ = try FileManager.default.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)"#
        XCTAssertEqual(Self.violations(in: readOnly, path: path), [])
    }

    func testReadOnlyRejectionExceptionCannotHideFixtureCreationOrAnotherFunction() {
        let prefix = #"let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!; let forbiddenParent = applicationSupport.appendingPathComponent("StorageCleanerMacTests-\(UUID().uuidString)"); "#
        let name = "testSystemDiskManagerRejectsNonBenchmarkApplicationSupportRoot"
        let path = "StorageCleanerMacTests/MacBenchmarkIOTests.swift"
        XCTAssertEqual(Self.violations(in: "func \(name)() { " + prefix + "defer { TestFileSystem.remove(forbiddenParent) } }", path: path), [])
        for source in [
            "func \(name)() { " + prefix + "try FileManager.default.createDirectory(at: forbiddenParent, withIntermediateDirectories: true) }",
            "func another() { " + prefix + "TestFileSystem.remove(forbiddenParent) }",
            "func \(name)() { let forbiddenParent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!; TestFileSystem.remove(forbiddenParent) }"
        ] { XCTAssertFalse(Self.violations(in: source, path: path).isEmpty, source) }
    }

    func testGuardFindsAnInjectedViolationInATemporarySourceCopy() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let tests = home.appendingPathComponent("Tests")
        let directory = tests.appendingPathComponent("StorageCleanerMacTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("MenuBarSimplePanelQuitTests.swift")
        let copy = directory.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        XCTAssertEqual(try Self.violations(inTestsDirectory: tests), [])
        let source = try String(contentsOf: copy, encoding: .utf8)
        try (source + "\nfunc hygieneCounterproof() { UserDefaults.standard.set(true, forKey: \"hygiene.counterproof\") }\n")
            .write(to: copy, atomically: true, encoding: .utf8)
        let failures = try Self.violations(inTestsDirectory: tests)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("写标准偏好域") == true)
    }

    func testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory() throws {
        let fixture = TestPreferenceDomain.make()
        defer { TestPreferenceDomain.cleanup(suiteName: fixture.suiteName) }
        let directory = URL(fileURLWithPath: fixture.suiteName).deletingLastPathComponent()
        XCTAssertTrue(TestPreferenceDomain.isTemporarySuiteName(fixture.suiteName))
        fixture.defaults.set(42, forKey: "hygiene.value")
        XCTAssertTrue(fixture.defaults.synchronize())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.suiteName + ".plist"))
        TestPreferenceDomain.cleanup(suiteName: fixture.suiteName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testTemporarySuiteCanBeReopenedOnAWorkerThread() async throws {
        let fixture = TestPreferenceDomain.make()
        let suiteName = fixture.suiteName
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let saved = await Task.detached {
            guard let defaults = TestPreferenceDomain.open(suiteName: suiteName) else { return false }
            defaults.set(7, forKey: "hygiene.worker")
            return defaults.synchronize()
        }.value
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.defaults.integer(forKey: "hygiene.worker"), 7)
    }

    func testPathGuardRejectsPlainDomainsAndPathsOutsideTheTemporaryDirectory() {
        XCTAssertFalse(TestPreferenceDomain.isTemporarySuiteName("SomeTests.UUID"))
        XCTAssertFalse(TestPreferenceDomain.isIsolatedSuiteName("/Users/fixture/.storage-cleaner-owned/suite"))
        XCTAssertFalse(TestPreferenceDomain.isTemporarySuiteName("/Users/fixture/Library/Preferences/test"))
        XCTAssertFalse(TestPreferenceDomain.isTemporarySuiteName(FileManager.default.temporaryDirectory.path))
    }

    func testReviewThreeCounterproofCatalogRejectsHazardsAndPreservesAllowedSources() throws {
        struct Case: Decodable { let source: String; let expect_rejection: Bool; let `case`: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Hygiene-3/source-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        for entry in cases {
            let failures = Self.violations(in: entry.source, path: "StorageCleanerMacTests/Counterproof.swift")
            XCTAssertEqual(!failures.isEmpty, entry.expect_rejection, "\(entry.case): \(failures)")
        }
    }

    func testLongMaskedInterpolationHasBoundedGuardCostAndStillRejectsWrites() {
        // Same shape as a masked SQL literal: long whitespace / identifier /
        // whitespace. The pre-review write regex needs about 23 s for n=1000.
        let padding = String(repeating: " ", count: 1_000)
        // Five whitespace-only closure heads also protect the possessive `\s*+`
        // in TestSourceFacts. The old head regex takes about five seconds here.
        let closureHeads = String(repeating: "; run {" + String(repeating: " ", count: 500) + "}", count: 5)
        let source = padding + "appIDColumn" + padding + closureHeads
            + "; ((UserDefaults . standard)).set(true, forKey: key)"
        let clock = ContinuousClock()
        let start = clock.now
        let failures = Self.violations(in: source, path: "StorageCleanerMacTests/Counterproof.swift")
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(failures.count, 1, "复杂度样例仍须检出真实标准域写入")
        XCTAssertTrue(failures.contains { $0.contains("写标准偏好域：set") })
        XCTAssertLessThan(elapsed, .seconds(2), "长空白与插值标识符不能触发正则回溯退化")
    }

    func testReviewFourCounterproofCatalogRejectsHazardsAndPreservesAllowedSources() throws {
        struct Case: Decodable { let source: String; let expect_rejection: Bool; let `case`: String }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Hygiene-4/source-cases.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        for entry in cases {
            let failures = Self.violations(in: entry.source, path: "StorageCleanerMacTests/Counterproof.swift")
            XCTAssertEqual(!failures.isEmpty, entry.expect_rejection, "\(entry.case): \(failures)")
        }
    }

    func testFactsCacheRetainsPositionAndCycleContextWithoutRepeatedParsing() {
        let source = "var prefs = UserDefaults.standard; prefs = isolated; prefs.set(1, forKey: key)"
        let analysis = TestSourceFacts(code: source, literals: source)
        let string = source as NSString
        let before = string.range(of: "prefs = isolated")
        let after = string.range(of: "prefs.set")
        let early = NSRange(location: before.location, length: 5)
        let late = NSRange(location: after.location, length: 5)
        XCTAssertTrue(analysis.facts(in: early).standard)
        XCTAssertFalse(analysis.facts(in: late).standard)
        let evaluations = analysis.factsEvaluationCount
        for _ in 0..<100 {
            XCTAssertTrue(analysis.facts(in: early).standard)
            XCTAssertFalse(analysis.facts(in: late).standard)
        }
        XCTAssertEqual(analysis.factsEvaluationCount, evaluations, "重复查询必须命中缓存")
        let cyclic = "class Fixture { var prefs: UserDefaults; func setUp() { prefs = alias }; var alias = prefs; func dangerous() { alias = UserDefaults.standard }; func write() { prefs.set(1, forKey: key) } }"
        let cycle = TestSourceFacts(code: cyclic, literals: cyclic)
        let use = (cyclic as NSString).range(of: "prefs.set")
        XCTAssertTrue(cycle.facts(in: NSRange(location: use.location, length: 5)).standard,
                      "访问集合不同的递归查询不能共享截断结果")
    }

    /// 逐文件白名单只允许 argumentDomain 的内存覆盖，数量锁定，不能为持久化写兜底。
    /// 各条均来自现有语言 scope：L10n 无注入点，需覆盖语言并恢复且通知缓存失效。
    private static let volatileWriteAllowlist: [String: Int] = [
        "StorageCleanerMacTests/BenchmarkMonitorLayoutTests.swift": 2, // 跑分布局中英矩阵及恢复。
        "StorageCleanerMacTests/CalibrationLanguageScope.swift": 2, // 共用语言 scope（首页布局、健康事件、安全检查等中英矩阵）及恢复；b3bacd0c 自 ConceptLandingNativeLayoutRegressionTests 移出。
        "StorageCleanerMacTests/CleanupReportSkipPresentationTests.swift": 2, // 跳过分组中英文案及恢复（r2-u1-followups）。
        "StorageCleanerMacTests/ControlPaletteTests.swift": 2, // 系统控制面板布局中英矩阵及恢复。
        "StorageCleanerMacTests/ExternalMigrationReceiptTests.swift": 2, // 搬家回执文案及恢复。
        "StorageCleanerMacTests/FanControlModeCardTests.swift": 2, // 风扇卡布局中英矩阵及恢复。
        "StorageCleanerMacTests/FileAnalysisTrashTests.swift": 2, // 文件分析移到废纸篓文案及恢复。
        "StorageCleanerMacTests/GeekOverviewLabelLayoutTests.swift": 2, // 极客概览标签及恢复。
        "StorageCleanerMacTests/GeekVPNManagementActionTests.swift": 2, // VPN 操作标签及恢复。
        "StorageCleanerMacTests/HealthCapabilityLayoutTests.swift": 2, // 健康页能力提示及恢复。
        "StorageCleanerMacTests/MemoryHeadroomSysctlTests.swift": 2, // 内存余量文案及恢复。
        "StorageCleanerMacTests/MenuBarSecondaryVisualConsistencyTests.swift": 2, // 二级页视觉矩阵及恢复。
        "StorageCleanerMacTests/MiniWindowConsistencyRuleTests.swift": 2, // 小窗一致性文案及恢复。
        "StorageCleanerMacTests/MiniWindowIStatHistoryLayoutTests.swift": 2, // D121 三级历史页中英文尺寸及恢复。
        "StorageCleanerMacTests/MiniWindowLogicTestSupport.swift": 2, // 小窗逻辑共用语言 scope 及恢复。
        "StorageCleanerMacTests/MiniWindowRowLayoutTests.swift": 2, // 小窗行布局中英矩阵及恢复。
        "StorageCleanerMacTests/SafeCleanupScopeCardLayoutTests.swift": 2, // 清理范围卡中英矩阵及恢复。
        "StorageCleanerMacTests/TestPreferenceDomain.swift": 1 // 新共用 scope；语言／首次授权无注入点，只覆盖内存。
    ]

    private static func violations(in source: String, path: String) -> [String] {
        let lexical = lexicalViews(source)
        let code = lexical.code
        let analysis = TestSourceFacts(code: code, literals: lexical.literals)
        var violations: [String] = []
        let suites = matches(#"(?:\b(?:NS)?UserDefaults\s*(?:\.\s*init\s*)?|\.\s*init\s*)\(\s*suiteName\s*:"#, in: code)
        if path == "StorageCleanerMacTests/TestPreferenceDomain.swift" {
            if suites.count != 1 { violations.append("偏好工厂应只有一个受路径检查保护的 suite 创建入口") }
        } else if !suites.isEmpty {
            violations.append("必须通过 TestPreferenceDomain 创建／重开临时偏好域")
        }
        for type in ["UserDefaults", "NSUserDefaults"] {
            for call in analysis.constructors(of: type) where call.arguments.isEmpty {
                violations.append("无参数偏好实例会回到标准域；必须使用 TestPreferenceDomain")
            }
        }
        let standardDefaults = matches(#"[(,]\s*(?:\w+\s+)?\w+\s*:\s*(?:NS)?UserDefaults[!?]?\s*=\s*(?:(?:NS)?UserDefaults\s*)?\.\s*standard\b"#, in: code)
        if standardDefaults.contains(where: { !analysis.isReadOnlyPreferenceParameter(defaultIn: $0.range) }) {
            violations.append("测试辅助的标准域默认参数无法证明只读；不得写入或传出偏好对象")
        }
        let writes = matches(#"((?:\(\s*+)*+(?:(?:NS)?UserDefaults\s*+\.\s*+standard|(?:self\s*+\.\s*+)?\b\w++)(?:\s*+\))*+)\s*+\.\s*+(set|setValue|setValuesForKeys|setPersistentDomain|removeObject|removePersistentDomain|register|addSuite|removeSuite|synchronize|setVolatileDomain|removeVolatileDomain)\s*\("#, in: code)
        var volatileCount = 0
        for write in writes where analysis.facts(in: write.range(at: 1)).standard {
            let method = analysis.text(write.range(at: 2))
            let arguments = analysis.arguments(after: NSMaxRange(write.range))
            if method == "setVolatileDomain", let name = arguments["forName"],
               !matches(#"\A\s*(?:NS)?UserDefaults\s*\.\s*argumentDomain\s*\z"#, in: analysis.text(name)).isEmpty {
                volatileCount += 1
            } else {
                let prefix = (code as NSString).substring(to: write.range.location)
                violations.append("第 \(prefix.filter { $0 == "\n" }.count + 1) 行写标准偏好域：\(method)")
            }
        }
        if volatileCount != volatileWriteAllowlist[path, default: 0] {
            violations.append("argumentDomain 内存覆盖数量不在逐条白名单内：\(volatileCount)")
        }
        if !matches(#"\bCFPreferences(?:Set\w*|AppSynchronize)\s*\("#, in: code).isEmpty {
            violations.append("测试不得调用 CFPreferences 写入／同步接口")
        }
        let factoryPath = "StorageCleanerMacTests/TestScanStoreFactory.swift"
        let stores = analysis.constructors(of: "ScanStore")
        if path == factoryPath {
            if stores.count != 1 { violations.append("ScanStore 测试工厂应只有一个完整注入的构造入口") }
            let required: Set<String> = [
                "preferences", "scanHistoryDefaults", "cleanupPreferences", "samplingGaps", "systemEnergyAccumulator",
                "menuBarPowerHistoryURL", "scanHeavyWorkOperations", "uninstallMoves", "fileAnalysisTrashEnvironment",
                "cleanupExecutor", "cleanupRecoveryService", "cleanupOwnerQuitService", "memoryCoordinator",
                "cleanupUserHomeURL", "operationJournal", "operationTrashURL", "historyLoader", "cleanReportLoader",
                "restoreSavedAccessOperation", "interruptedOperationReconciler", "startupItemManager",
                "applicationUpdateCoordinator", "applicationUpdateGracefulQuitRequester", "applicationUpdateRelauncher",
                "websiteUpdateWorkflow", "fanControlProvider"
            ]
            for store in stores {
                for (name, helper) in [("dataRoot", "requireOwnedData"), ("operationHome", "requireOwned")] {
                    guard let initializer = analysis.initializer(of: name, before: store.range.location),
                          analysis.facts(in: initializer).ownershipChecked,
                          !matches(#"\bTestFileSystem\s*\.\s*"# + helper + #"\s*\("#, in: analysis.text(initializer)).isEmpty else {
                        violations.append("测试工厂 \(name) 必须验证当前测试拥有的隔离根")
                        continue
                    }
                }
                let missing = required.subtracting(store.arguments.keys)
                if !missing.isEmpty { violations.append("测试工厂缺少必要注入：\(missing.sorted().joined(separator: ", "))") }
                for label in required {
                    guard let value = store.arguments[label] else { continue }
                    let text = analysis.text(value).trimmingCharacters(in: .whitespacesAndNewlines)
                    let facts = analysis.facts(in: value)
                    if text.isEmpty || facts.mayBeNil || facts.hasLiveDefault || facts.isUnisolatedHome {
                        violations.append("测试工厂注入 \(label) 不得回落到 nil／standard／shared／live 或真实 home")
                    }
                    if ["cleanupUserHomeURL", "operationJournal", "operationTrashURL", "menuBarPowerHistoryURL", "fileAnalysisTrashEnvironment"].contains(label), !facts.ownershipChecked {
                        violations.append("测试工厂 \(label) 必须通过 TestFileSystem.requireOwned 验证本测试根")
                    }
                }
            }
        } else if !stores.isEmpty {
            violations.append("必须通过 ScanStore.makeForTests 构造测试 store")
        }
        for call in analysis.calls(matching: #"\bScanStore\s*\.\s*makeForTests\s*\("#) {
            for (label, value) in call.arguments where analysis.facts(in: value).hasLiveDefault {
                violations.append("makeForTests 覆盖参数 \(label) 不得使用 standard／shared／live（含别名）")
            }
            for label in ["dataDirectory", "menuBarPowerHistoryURL", "systemEnergyAccumulator", "cleanupUserHomeURL",
                          "operationJournal", "operationTrashURL", "fileAnalysisTrashEnvironment"] {
                if let value = call.arguments[label], analysis.facts(in: value).isUnisolatedHome {
                    violations.append("makeForTests 覆盖参数 \(label) 不得使用未隔离的真实 home／Library／Trash")
                }
            }
            if let operations = call.arguments["scanHeavyWorkOperations"],
               !matches(#"\A\s*\.\s*init\s*\("#, in: analysis.text(operations)).isEmpty {
                violations.append("部分 Operations 必须通过 TestOperationFactory 构造")
            }
        }
        if analysis.hasUnsafeSingletonAccess() {
            violations.append("测试不得间接创建真实风扇／电源单例；必须通过测试操作工厂注入")
        }
        if !analysis.unsafeStorageSources().isEmpty {
            violations.append("跨类型存储入口不得持有真实 home／standard／shared；请显式注入隔离值")
        }
        for mutation in matches(#"((?:MenuBarSamplingGaps\s*\.\s*shared)|\b\w+)\s*\.\s*(?:begin|end)\s*\("#, in: code)
            where analysis.facts(in: mutation.range(at: 1)).shared {
            violations.append("测试必须注入临时域的采样间隙 store")
        }
        if !analysis.constructors(of: "MenuBarStatusPanelRoot").isEmpty {
            violations.append("测试不得构造含缺省真实风扇入口的 MenuBarStatusPanelRoot；请使用显式注入的视图")
        }
        let requiredArguments: [String: Set<String>] = [
            "FanControlCoordinator": ["defaults", "requestSender"],
            "BatteryHealthService": ["powerModeWriter"],
            "ComputerHealthStore": ["probe", "batteryPowerModeController"],
            "PrivilegedBatteryPowerModeCommandRunner": ["fanControlProvider"],
            "ControlPaletteRootView": ["fanControl"],
            "MenuBarAdvancedStatusView": ["fanControl"],
            "SettingsView": ["fanControl"],
            "MenuBarStatusController": ["fanControlProvider"],
            "GeekDashboardConfigurationStore": ["defaults", "fanControlProvider"],
            "SystemEnergyAccumulator": ["fileURL", "samplingGaps"],
            "MenuBarAuxiliaryMonitorState": ["powerHistoryURL"],
            "MenuBarSamplingGaps": ["defaults"]
        ]
        for (type, required) in requiredArguments {
            for call in analysis.constructors(of: type) {
                // An argument label alone does not prove the concrete Swift type.
                // Preserve the existing controller requirement for label-inferred
                // health values; confirmed ComputerHealthStore constructors also
                // require the designated initializer's explicit fixture probe.
                let callRequired = type == "ComputerHealthStore" && !call.typeIsExplicit
                    ? required.subtracting(["probe"]) : required
                if !callRequired.isSubset(of: Set(call.arguments.keys)) {
                    violations.append("\(type) 必须显式注入 \(callRequired.sorted().joined(separator: ", "))")
                }
                for label in required {
                    guard let value = call.arguments[label] else { continue }
                    if analysis.facts(in: value).hasLiveDefault {
                        violations.append("\(type).\(label) 不得传入 standard／shared／live（含别名）")
                    }
                    let facts = analysis.facts(in: value)
                    if ["probe", "fanControl", "fanControlProvider", "requestSender", "powerModeWriter", "batteryPowerModeController"].contains(label), facts.mayBeNil {
                        violations.append("\(type).\(label) 不得使用可能为 nil 的值回落生产入口")
                    }
                    if type == "ComputerHealthStore", label == "probe",
                       !analysis.constructors(of: "DefaultComputerHealthProbe").isEmpty {
                        violations.append("ComputerHealthStore.probe 不得使用真实 DefaultComputerHealthProbe")
                    }
                    if facts.isUnisolatedHome && (label != "probe" || facts.runtimeHome) {
                        violations.append("\(type).\(label) 不得把持久数据写入真实 home")
                    }
                }
            }
        }
        for call in analysis.constructors(of: "LargeFilesStore") {
            if call.arguments["storageAnalysisOperation"] != nil || path == "StorageCleanerMacTests/StorageTreemapLayoutTests.swift" {
                if let environment = call.arguments["trashEnvironment"], !analysis.facts(in: environment).live { continue }
                violations.append("模拟文件分析结果必须注入夹具环境，不能读取 live Library")
            }
        }
        // 仅 Tests 支持层可以直接构造 Operations，且每个写入口都必须显式覆盖。
        let writers: Set<String> = ["moveToTrash", "emptyTrash", "restoreFromTrash", "optimizeMemory", "runHomebrewUpgrade", "prepareOneClickUpdate"]
        for call in analysis.constructors(of: "ScanHeavyWorkService.Operations") {
            if path != "StorageCleanerMacTests/TestOperationFactory.swift" || !writers.isSubset(of: Set(call.arguments.keys)) {
                violations.append("Operations 默认写操作不安全；必须通过 TestOperationFactory 完整封闭")
            }
        }
        for call in analysis.constructors(of: "ScanHeavyWorkService") {
            if call.arguments["operations"] == nil
                || call.arguments["operations"].map({ !matches(#"\A\s*\.\s*init\s*\("#, in: analysis.text($0)).isEmpty }) == true {
                violations.append("ScanHeavyWorkService 必须注入安全操作工厂的结果")
            }
        }
        violations += realLibraryPathViolations(analysis: analysis, path: path)
        return violations
    }

    /// 这些字符串只用于 D54 保护规则模型及隔离 home 内的夹具；真实根写入检查仍执行。
    private static let fixtureDataPathAllowlist: [String: Int] = [
        "StorageCleanerMacTests/FileAnalysisTrashProtectedScopeTests.swift": 3,
        "StorageCleanerMacTests/FileAnalysisTrashTests.swift": 3,
        // 仅规则模型的虚拟 /Users/fixture 字符串；不创建目录、不写真实应用数据。
        "StorageCleanerMacTests/FileAnalysisTrashCostTests.swift": 1,
        "StorageCleanerMacTests/CleanupExecutionSafetyTests.swift": 1
    ]

    private static func realLibraryPathViolations(analysis: TestSourceFacts, path: String) -> [String] {
        var failures: [String] = []
        if !matches(#"~[/]Library[/](?:Caches|Preferences)"#, in: analysis.literals).isEmpty {
            failures.append("测试不得引用真实用户的 Library 缓存／偏好路径")
        }
        let dataPaths = matches(#"Application Support[/]StorageCleanerMac"#, in: analysis.literals)
        if dataPaths.count != fixtureDataPathAllowlist[path, default: 0] {
            failures.append("本应用数据目录只允许有说明的隔离夹具字符串")
        }
        let sinks: [String: Set<String>] = [
            "createDirectory": ["at", "atPath"], "createFile": ["atPath"], "write": ["to", "toFile"],
            "removeItem": ["at", "atPath"], "moveItem": ["at", "atPath", "to", "toPath"],
            "copyItem": ["to", "toPath"], "linkItem": ["to", "toPath"], "trashItem": ["at"],
            "createSymbolicLink": ["at", "atPath"], "setAttributes": ["ofItemAtPath"],
            "replaceItemAt": ["at", "withItemAt"], "FileHandle": ["forWritingTo", "forUpdating"],
            "registerCleanup": ["of"]
        ]
        func isBenchmarkRejectionCleanup(at position: Int, value: NSRange) -> Bool {
            guard path == "StorageCleanerMacTests/MacBenchmarkIOTests.swift",
                  analysis.function(at: position) == "testSystemDiskManagerRejectsNonBenchmarkApplicationSupportRoot",
                  analysis.text(value).trimmingCharacters(in: .whitespacesAndNewlines) == "forbiddenParent",
                  let declaration = analysis.initializer(of: "forbiddenParent", before: position) else { return false }
            return !matches(#"\A\s*applicationSupport\s*\.\s*appendingPathComponent\s*\(\s*"StorageCleanerMacTests-\\\(UUID\(\)\.uuidString\)"\s*(?:,\s*isDirectory\s*:\s*true\s*)?\)\s*\z"#,
                            in: analysis.text(declaration, strings: true)).isEmpty
        }
        var benchmarkCleanupExceptions = 0
        for (method, call) in analysis.calls(named: Set(sinks.keys)) {
            for label in sinks[method, default: []] {
                guard let value = call.arguments[label], analysis.facts(in: value).isUnsafeWritePath else { continue }
                // 原有拒绝测试的唯一兜底：只删除 UUID 命名的 forbiddenParent。
                // 不豁免该函数的创建／写入，也不豁免其他函数或其他参数。
                if method == "removeItem", label == "at", isBenchmarkRejectionCleanup(at: call.range.location, value: value) {
                    benchmarkCleanupExceptions += 1
                    continue
                }
                failures.append("真实 home 派生路径用于 \(method).\(label)；请注入隔离 home")
            }
        }
        // TestFileSystem.remove 也是写入。只读拒绝测试的精确兜底同上，最多一处。
        for call in analysis.calls(matching: #"\bTestFileSystem\s*\.\s*remove\s*\("#) {
            guard let value = analysis.firstArgument(after: NSMaxRange(call.range)),
                  analysis.facts(in: value).isUnsafeWritePath else { continue }
            if isBenchmarkRejectionCleanup(at: call.range.location, value: value) {
                benchmarkCleanupExceptions += 1
            } else { failures.append("真实 home 派生路径用于夹具清理") }
        }
        if benchmarkCleanupExceptions > 1 { failures.append("只读拒绝测试的清理例外最多一处") }
        for call in analysis.calls(matching: #"\.\s*url\s*\("#) {
            if let create = call.arguments["create"], analysis.text(create).trimmingCharacters(in: .whitespacesAndNewlines) == "true",
               let end = call.arguments.values.map(NSMaxRange).max(),
               analysis.facts(in: NSRange(location: call.range.location, length: end - call.range.location)).isUnsafeWritePath {
                failures.append("系统目录 API 的 create: true 会改写真 home")
            }
        }
        return failures
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        // 固定规则若无效应立即暴露，不能把解析失败当成没有违规。
        TestSourceRegex.matches(pattern, in: text)
    }

    /// 保留换行，屏蔽注释和字符串里的源码断言；插值中的执行代码仍参与检查。
    /// 支持嵌套注释、raw 和多行字符串，避免旧源码契约断言触发误报。
    private static func lexicalViews(_ source: String) -> (code: String, literals: String) {
        let characters = Array(source)
        var output = characters.map(String.init)
        var literalOutput = output
        var wideSpaces: [Int: String] = [:]
        var index = 0
        func begins(_ text: String, at start: Int) -> Bool {
            guard start + text.count <= characters.count else { return false }
            for (offset, character) in text.enumerated() where characters[start + offset] != character {
                return false
            }
            return true
        }
        func blank(_ start: Int, _ end: Int, comments: Bool = true) {
            for position in start..<min(end, characters.count) where output[position] != "\n" {
                let width = output[position].utf16.count
                let spaces: String
                switch width {
                case 1: spaces = " "
                case 2: spaces = "  "
                default:
                    if let cached = wideSpaces[width] { spaces = cached }
                    else {
                        spaces = String(repeating: " ", count: width)
                        wideSpaces[width] = spaces
                    }
                }
                output[position] = spaces
                if comments { literalOutput[position] = spaces }
            }
        }
        func blankLiteral(_ start: Int, _ end: Int) { blank(start, end, comments: false) }
        func scanCode(interpolation: Bool) {
            var parentheses = 0
            while index < characters.count {
                let start = index
                if characters[index] == "/" && begins("//", at: index) {
                    while index < characters.count && characters[index] != "\n" { index += 1 }
                    blank(start, index)
                } else if characters[index] == "/" && begins("/*", at: index) {
                    var depth = 1
                    index += 2
                    while index < characters.count && depth > 0 {
                        if characters[index] == "/" && begins("/*", at: index) { depth += 1; index += 2 }
                        else if characters[index] == "*" && begins("*/", at: index) { depth -= 1; index += 2 }
                        else { index += 1 }
                    }
                    blank(start, index)
                } else {
                    var hashes = 0
                    while index + hashes < characters.count && characters[index + hashes] == "#" { hashes += 1 }
                    let quote = index + hashes
                    if quote < characters.count && characters[quote] == "\"" {
                        let width = begins("\"\"\"", at: quote) ? 3 : 1
                        let closing = String(repeating: "\"", count: width) + String(repeating: "#", count: hashes)
                        let escape = "\\" + String(repeating: "#", count: hashes)
                        let interpolationOpening = escape + "("
                        index = quote + width
                        blankLiteral(start, index)
                        while index < characters.count {
                            let literalStart = index
                            if characters[index] == "\\" && begins(interpolationOpening, at: index) {
                                index += escape.count + 1
                                blankLiteral(literalStart, index)
                                scanCode(interpolation: true)
                            } else if characters[index] == "\\" && begins(escape, at: index) {
                                index += escape.count + 1
                                blankLiteral(literalStart, index)
                            } else if characters[index] == "\"" && begins(closing, at: index) {
                                index += closing.count
                                blankLiteral(literalStart, index)
                                break
                            } else {
                                index += 1
                                blankLiteral(literalStart, index)
                            }
                        }
                    } else if interpolation && characters[index] == ")" {
                        index += 1
                        if parentheses == 0 { blankLiteral(start, index); return }
                        parentheses -= 1
                    } else {
                        if interpolation && characters[index] == "(" { parentheses += 1 }
                        index += 1
                    }
                }
            }
        }
        scanCode(interpolation: false)
        return (output.joined(), literalOutput.joined())
    }
}
